// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { LibNexusVaultStorage } from "../libraries/LibNexusVaultStorage.sol";
import { LibNexusVaultAuth } from "../libraries/LibNexusVaultAuth.sol";
import { LibNexusVault } from "../libraries/LibNexusVault.sol";
import "../errors/NexusVaultErrors.sol";

/**
 * @title NexusVaultAdminFacet
 * @author BaseVol Team
 * @notice Administrative functions for NexusVault management
 * @dev Provides vault registry management, fee configuration, access control,
 *      and emergency operations
 *
 * Access levels:
 * - Owner: Full control (ownership transfer, shutdown)
 * - Admin: Day-to-day management (vault config, fees, keepers)
 * - Keeper: Operational tasks (handled in separate facet)
 *
 * Key features:
 * - Multi-vault registry management (add, remove, activate, deactivate)
 * - Weight configuration with min/max bounds
 * - Fee configuration with reasonable limits
 * - Deposit cap management
 * - Emergency pause/unpause and shutdown
 */
contract NexusVaultAdminFacet {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Maximum fee allowed (20% = 0.2e18)
    uint256 internal constant MAX_MANAGEMENT_FEE = 0.2e18;

    /// @dev Maximum performance fee allowed (50% = 0.5e18)
    uint256 internal constant MAX_PERFORMANCE_FEE = 0.5e18;

    /// @dev Maximum deposit/withdraw fee allowed (5% = 0.05e18)
    uint256 internal constant MAX_ENTRY_EXIT_FEE = 0.05e18;

    /// @dev Precision for percentage calculations (1e18 = 100%)
    uint256 internal constant FLOAT_PRECISION = 1e18;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new vault is added
    event VaultAdded(
        address indexed vault,
        uint256 targetWeight,
        uint256 maxWeight,
        uint256 minWeight
    );

    /// @notice Emitted when a vault is removed
    event VaultRemoved(address indexed vault);

    /// @notice Emitted when a vault is activated
    event VaultActivated(address indexed vault);

    /// @notice Emitted when a vault is deactivated
    event VaultDeactivated(address indexed vault);

    /// @notice Emitted when vault weights are updated
    event VaultWeightsUpdated(
        address indexed vault,
        uint256 targetWeight,
        uint256 maxWeight,
        uint256 minWeight
    );

    /// @notice Emitted when vault deposit cap is updated
    event VaultDepositCapUpdated(address indexed vault, uint256 depositCap);

    /// @notice Emitted when fee configuration is updated
    event FeeConfigUpdated(
        uint256 managementFee,
        uint256 performanceFee,
        uint256 depositFee,
        uint256 withdrawFee,
        address feeRecipient
    );

    /// @notice Emitted when rebalance config is updated
    event RebalanceConfigUpdated(
        uint256 threshold,
        uint256 maxSlippage,
        uint256 cooldownPeriod
    );

    /// @notice Emitted when deposit caps are updated
    event DepositCapsUpdated(uint256 totalCap, uint256 userCap);

    /// @notice Emitted when admin is changed
    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);

    /// @notice Emitted when a keeper is added
    event KeeperAdded(address indexed keeper);

    /// @notice Emitted when a keeper is removed
    event KeeperRemoved(address indexed keeper);

    /// @notice Emitted when vault is paused
    event Paused(address indexed by);

    /// @notice Emitted when vault is unpaused
    event Unpaused(address indexed by);

    /// @notice Emitted when vault is shutdown
    event Shutdown(address indexed by);

    /// @notice Emitted when ownership is transferred
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    /*//////////////////////////////////////////////////////////////
                            VAULT MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Add a new underlying vault
     * @dev Validates vault asset matches NexusVault asset
     *
     * Requirements:
     * - Caller must be admin or owner
     * - Vault must not already exist
     * - Vault asset must match NexusVault asset
     * - Weights must be valid (min <= target <= max)
     *
     * @param vault ERC4626 vault address to add
     * @param targetWeight Target allocation weight (1e18 = 100%)
     * @param maxWeight Maximum allowed weight
     * @param minWeight Minimum allowed weight
     */
    function addVault(
        address vault,
        uint256 targetWeight,
        uint256 maxWeight,
        uint256 minWeight
    ) external {
        LibNexusVaultAuth.enforceIsAdmin();
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        // Validate vault
        if (vault == address(0)) revert InvalidVault(vault);
        if (s.vaultConfigs[vault].vault != address(0)) {
            revert VaultAlreadyExists(vault);
        }

        // Validate asset matches
        address vaultAsset = IERC4626(vault).asset();
        if (vaultAsset != address(s.asset)) {
            revert AssetMismatch(address(s.asset), vaultAsset);
        }

        // Validate weights
        _validateWeights(targetWeight, maxWeight, minWeight);

        // Add vault to registry
        s.vaultList.push(vault);
        s.vaultIndexes[vault] = s.vaultList.length; // 1-indexed for existence check

        s.vaultConfigs[vault] = LibNexusVaultStorage.VaultConfig({
            vault: vault,
            targetWeight: targetWeight,
            maxWeight: maxWeight,
            minWeight: minWeight,
            isActive: true,
            depositCap: 0 // 0 means unlimited
        });

        s.activeVaultCount++;

        emit VaultAdded(vault, targetWeight, maxWeight, minWeight);
    }

    /**
     * @notice Remove a vault from the registry
     * @dev Only removes empty vaults (no assets deposited)
     *
     * Requirements:
     * - Caller must be admin or owner
     * - Vault must exist
     * - Vault must have no assets
     *
     * @param vault Vault address to remove
     */
    function removeVault(address vault) external {
        LibNexusVaultAuth.enforceIsAdmin();
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        // Validate vault exists
        if (s.vaultConfigs[vault].vault == address(0)) {
            revert VaultNotFound(vault);
        }

        // Ensure vault is empty
        uint256 vaultAssets = LibNexusVault.assetsInVault(vault);
        if (vaultAssets > 0) {
            revert VaultHasBalance(vault, vaultAssets);
        }

        // Update active count if was active
        if (s.vaultConfigs[vault].isActive) {
            s.activeVaultCount--;
        }

        // Remove from vaultList (swap and pop)
        uint256 index = s.vaultIndexes[vault] - 1; // Convert to 0-indexed
        uint256 lastIndex = s.vaultList.length - 1;

        if (index != lastIndex) {
            address lastVault = s.vaultList[lastIndex];
            s.vaultList[index] = lastVault;
            s.vaultIndexes[lastVault] = index + 1; // 1-indexed
        }

        s.vaultList.pop();
        delete s.vaultIndexes[vault];
        delete s.vaultConfigs[vault];

        emit VaultRemoved(vault);
    }

    /**
     * @notice Activate a vault for deposits
     * @param vault Vault address to activate
     */
    function activateVault(address vault) external {
        LibNexusVaultAuth.enforceIsAdmin();
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        if (s.vaultConfigs[vault].vault == address(0)) {
            revert VaultNotFound(vault);
        }
        if (s.vaultConfigs[vault].isActive) {
            revert VaultAlreadyActive(vault);
        }

        s.vaultConfigs[vault].isActive = true;
        s.activeVaultCount++;

        emit VaultActivated(vault);
    }

    /**
     * @notice Deactivate a vault (stops new deposits, allows withdrawals)
     * @param vault Vault address to deactivate
     */
    function deactivateVault(address vault) external {
        LibNexusVaultAuth.enforceIsAdmin();
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        if (s.vaultConfigs[vault].vault == address(0)) {
            revert VaultNotFound(vault);
        }
        if (!s.vaultConfigs[vault].isActive) {
            revert VaultNotActive(vault);
        }

        s.vaultConfigs[vault].isActive = false;
        s.activeVaultCount--;

        emit VaultDeactivated(vault);
    }

    /**
     * @notice Update vault weight configuration
     * @param vault Vault address
     * @param targetWeight New target weight
     * @param maxWeight New maximum weight
     * @param minWeight New minimum weight
     */
    function updateVaultWeights(
        address vault,
        uint256 targetWeight,
        uint256 maxWeight,
        uint256 minWeight
    ) external {
        LibNexusVaultAuth.enforceIsAdmin();
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        if (s.vaultConfigs[vault].vault == address(0)) {
            revert VaultNotFound(vault);
        }

        _validateWeights(targetWeight, maxWeight, minWeight);

        s.vaultConfigs[vault].targetWeight = targetWeight;
        s.vaultConfigs[vault].maxWeight = maxWeight;
        s.vaultConfigs[vault].minWeight = minWeight;

        emit VaultWeightsUpdated(vault, targetWeight, maxWeight, minWeight);
    }

    /**
     * @notice Update vault-specific deposit cap
     * @param vault Vault address
     * @param depositCap New deposit cap (0 = unlimited)
     */
    function updateVaultDepositCap(address vault, uint256 depositCap) external {
        LibNexusVaultAuth.enforceIsAdmin();
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        if (s.vaultConfigs[vault].vault == address(0)) {
            revert VaultNotFound(vault);
        }

        s.vaultConfigs[vault].depositCap = depositCap;

        emit VaultDepositCapUpdated(vault, depositCap);
    }

    /*//////////////////////////////////////////////////////////////
                            FEE CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update fee configuration
     * @dev Validates fees are within acceptable limits
     *
     * @param managementFee Annual management fee (max 20%)
     * @param performanceFee Performance fee on profits (max 50%)
     * @param depositFee Deposit fee (max 5%)
     * @param withdrawFee Withdrawal fee (max 5%)
     * @param feeRecipient Address to receive fees
     */
    function setFeeConfig(
        uint256 managementFee,
        uint256 performanceFee,
        uint256 depositFee,
        uint256 withdrawFee,
        address feeRecipient
    ) external {
        LibNexusVaultAuth.enforceIsAdmin();

        // Validate fee limits
        if (managementFee > MAX_MANAGEMENT_FEE) {
            revert FeeExceedsMaximum(managementFee, MAX_MANAGEMENT_FEE);
        }
        if (performanceFee > MAX_PERFORMANCE_FEE) {
            revert FeeExceedsMaximum(performanceFee, MAX_PERFORMANCE_FEE);
        }
        if (depositFee > MAX_ENTRY_EXIT_FEE) {
            revert FeeExceedsMaximum(depositFee, MAX_ENTRY_EXIT_FEE);
        }
        if (withdrawFee > MAX_ENTRY_EXIT_FEE) {
            revert FeeExceedsMaximum(withdrawFee, MAX_ENTRY_EXIT_FEE);
        }

        // Fee recipient required if any fee is set
        if (
            feeRecipient == address(0) &&
            (managementFee > 0 || performanceFee > 0 || depositFee > 0 || withdrawFee > 0)
        ) {
            revert InvalidFeeRecipient();
        }

        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        s.feeConfig = LibNexusVaultStorage.FeeConfig({
            managementFee: managementFee,
            performanceFee: performanceFee,
            depositFee: depositFee,
            withdrawFee: withdrawFee,
            feeRecipient: feeRecipient
        });

        emit FeeConfigUpdated(
            managementFee,
            performanceFee,
            depositFee,
            withdrawFee,
            feeRecipient
        );
    }

    /**
     * @notice Update rebalance configuration
     * @param threshold Deviation threshold to trigger rebalance
     * @param maxSlippage Maximum slippage allowed during rebalance
     * @param cooldownPeriod Minimum time between rebalances
     */
    function setRebalanceConfig(
        uint256 threshold,
        uint256 maxSlippage,
        uint256 cooldownPeriod
    ) external {
        LibNexusVaultAuth.enforceIsAdmin();

        // Validate reasonable limits
        if (threshold > FLOAT_PRECISION) {
            revert InvalidThreshold(threshold);
        }
        if (maxSlippage > 0.1e18) {
            // Max 10% slippage
            revert SlippageExceedsMaximum(maxSlippage, 0.1e18);
        }

        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        s.rebalanceConfig.rebalanceThreshold = threshold;
        s.rebalanceConfig.maxSlippage = maxSlippage;
        s.rebalanceConfig.cooldownPeriod = cooldownPeriod;

        emit RebalanceConfigUpdated(threshold, maxSlippage, cooldownPeriod);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSIT CAPS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update deposit caps
     * @param totalCap Maximum total deposits (0 = unlimited)
     * @param userCap Maximum per-user deposits (0 = unlimited)
     */
    function setDepositCaps(uint256 totalCap, uint256 userCap) external {
        LibNexusVaultAuth.enforceIsAdmin();

        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();
        s.totalDepositCap = totalCap;
        s.userDepositCap = userCap;

        emit DepositCapsUpdated(totalCap, userCap);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Transfer ownership to new address
     * @dev Only callable by current owner
     * @param newOwner New owner address
     */
    function transferOwnership(address newOwner) external {
        LibNexusVaultAuth.enforceIsOwner();

        if (newOwner == address(0)) revert InvalidAdmin();

        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();
        address previousOwner = s.owner;
        s.owner = newOwner;

        emit OwnershipTransferred(previousOwner, newOwner);
    }

    /**
     * @notice Set new admin address
     * @dev Only callable by owner
     * @param newAdmin New admin address
     */
    function setAdmin(address newAdmin) external {
        LibNexusVaultAuth.enforceIsOwner();

        if (newAdmin == address(0)) revert InvalidAdmin();

        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();
        address previousAdmin = s.admin;
        s.admin = newAdmin;

        emit AdminChanged(previousAdmin, newAdmin);
    }

    /**
     * @notice Add a keeper address
     * @param keeper Address to add as keeper
     */
    function addKeeper(address keeper) external {
        LibNexusVaultAuth.enforceIsAdmin();

        if (keeper == address(0)) revert InvalidKeeper();

        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        // Check not already a keeper
        address[] storage keepers = s.keepers;
        uint256 length = keepers.length;
        for (uint256 i = 0; i < length; ) {
            if (keepers[i] == keeper) revert KeeperAlreadyExists(keeper);
            unchecked {
                ++i;
            }
        }

        s.keepers.push(keeper);

        emit KeeperAdded(keeper);
    }

    /**
     * @notice Remove a keeper address
     * @param keeper Address to remove
     */
    function removeKeeper(address keeper) external {
        LibNexusVaultAuth.enforceIsAdmin();

        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();
        address[] storage keepers = s.keepers;
        uint256 length = keepers.length;

        for (uint256 i = 0; i < length; ) {
            if (keepers[i] == keeper) {
                // Swap and pop
                keepers[i] = keepers[length - 1];
                keepers.pop();
                emit KeeperRemoved(keeper);
                return;
            }
            unchecked {
                ++i;
            }
        }

        revert KeeperNotFound(keeper);
    }

    /*//////////////////////////////////////////////////////////////
                            EMERGENCY CONTROLS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pause the vault
     * @dev Stops all deposits and withdrawals
     */
    function pause() external {
        LibNexusVaultAuth.enforceIsAdmin();
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        if (s.paused) revert AlreadyPaused();

        s.paused = true;

        emit Paused(msg.sender);
    }

    /**
     * @notice Unpause the vault
     */
    function unpause() external {
        LibNexusVaultAuth.enforceIsAdmin();
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        if (!s.paused) revert NotPaused();
        if (s.shutdown) revert VaultIsShutdown();

        s.paused = false;

        emit Unpaused(msg.sender);
    }

    /**
     * @notice Permanently shutdown the vault
     * @dev Only allows withdrawals after shutdown. Cannot be reversed.
     */
    function shutdown() external {
        LibNexusVaultAuth.enforceIsOwner();
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        if (s.shutdown) revert VaultIsShutdown();

        s.shutdown = true;
        s.paused = false; // Allow withdrawals

        emit Shutdown(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                            EMERGENCY RECOVERY
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Recover stuck tokens (not the vault asset)
     * @dev Only for tokens accidentally sent to the contract
     * @param token Token address to recover
     * @param to Recipient address
     * @param amount Amount to recover
     */
    function recoverToken(
        address token,
        address to,
        uint256 amount
    ) external {
        LibNexusVaultAuth.enforceIsOwner();
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        // Cannot recover the vault asset
        if (token == address(s.asset)) {
            revert CannotRecoverAsset();
        }

        // Cannot recover underlying vault shares
        address[] storage vaultList = s.vaultList;
        uint256 length = vaultList.length;
        for (uint256 i = 0; i < length; ) {
            if (token == vaultList[i]) {
                revert CannotRecoverVaultShares(token);
            }
            unchecked {
                ++i;
            }
        }

        IERC20(token).safeTransfer(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Validate weight configuration
     * @param targetWeight Target weight
     * @param maxWeight Maximum weight
     * @param minWeight Minimum weight
     */
    function _validateWeights(
        uint256 targetWeight,
        uint256 maxWeight,
        uint256 minWeight
    ) internal pure {
        if (minWeight > targetWeight) {
            revert InvalidWeightConfig(targetWeight, maxWeight, minWeight);
        }
        if (targetWeight > maxWeight) {
            revert InvalidWeightConfig(targetWeight, maxWeight, minWeight);
        }
        if (maxWeight > FLOAT_PRECISION) {
            revert InvalidWeightConfig(targetWeight, maxWeight, minWeight);
        }
    }
}
