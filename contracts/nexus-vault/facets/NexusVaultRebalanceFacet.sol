// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { LibNexusVaultStorage } from "../libraries/LibNexusVaultStorage.sol";
import { LibNexusVaultAuth } from "../libraries/LibNexusVaultAuth.sol";
import { LibNexusVault } from "../libraries/LibNexusVault.sol";
import "../errors/NexusVaultErrors.sol";

/**
 * @title NexusVaultRebalanceFacet
 * @author BaseVol Team
 * @notice Rebalancing and fee collection operations for NexusVault
 * @dev Handles portfolio rebalancing across underlying vaults and periodic fee collection
 *
 * Key features:
 * - Automatic rebalancing based on deviation threshold
 * - Cooldown period between rebalances
 * - Slippage protection during rebalance
 * - Management fee collection (time-based)
 * - Performance fee collection (high water mark based)
 * - Fee minting as shares to fee recipient
 */
contract NexusVaultRebalanceFacet {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant FLOAT_PRECISION = 1e18;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted after successful rebalance
    event Rebalanced(
        uint256 indexed timestamp,
        uint256 totalAssets,
        address[] vaults,
        uint256[] oldAllocations,
        uint256[] newAllocations
    );

    /// @notice Emitted when management fee is collected
    event ManagementFeeCollected(
        uint256 feeAmount,
        uint256 feeShares,
        address recipient
    );

    /// @notice Emitted when performance fee is collected
    event PerformanceFeeCollected(
        uint256 feeAmount,
        uint256 feeShares,
        uint256 newHighWaterMark,
        address recipient
    );

    /// @notice ERC20 Transfer event (for fee share minting)
    event Transfer(address indexed from, address indexed to, uint256 value);

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Prevents reentrancy attacks
    modifier nonReentrant() {
        LibNexusVaultAuth.nonReentrantBefore();
        _;
        LibNexusVaultAuth.nonReentrantAfter();
    }

    /*//////////////////////////////////////////////////////////////
                            REBALANCE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Rebalance portfolio to target weights
     * @dev Callable by keepers, admin, or owner
     *
     * Flow:
     * 1. Validate operational state and cooldown
     * 2. Calculate current vs target allocations
     * 3. Withdraw from over-allocated vaults
     * 4. Deposit to under-allocated vaults
     * 5. Update last rebalance timestamp
     *
     * Requirements:
     * - Vault must not be paused or shutdown
     * - Cooldown period must have passed
     * - At least one active vault must exist
     */
    function rebalance() external nonReentrant {
        LibNexusVaultAuth.enforceIsKeeper();
        LibNexusVaultAuth.enforceOperational();

        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        // Check cooldown
        uint256 lastRebalance = s.rebalanceConfig.lastRebalanceTime;
        uint256 cooldown = s.rebalanceConfig.cooldownPeriod;
        if (block.timestamp < lastRebalance + cooldown) {
            revert RebalanceCooldownActive(lastRebalance + cooldown);
        }

        // Get current state
        uint256 totalAssetsBefore = LibNexusVault.totalAssets();
        if (totalAssetsBefore == 0) revert ZeroAmount();

        uint256 activeCount = s.activeVaultCount;
        if (activeCount == 0) revert NoActiveVaults();

        // Collect current allocations and calculate targets
        (
            address[] memory vaults,
            uint256[] memory oldAllocations,
            , // targetAllocations not used here
            int256[] memory deltas
        ) = _calculateRebalanceDeltas(totalAssetsBefore);

        // Execute rebalance
        _executeRebalance(vaults, deltas);

        // Verify slippage
        uint256 totalAssetsAfter = LibNexusVault.totalAssets();
        uint256 maxSlippage = s.rebalanceConfig.maxSlippage;
        uint256 minExpected = totalAssetsBefore.mulDiv(
            FLOAT_PRECISION - maxSlippage,
            FLOAT_PRECISION
        );

        if (totalAssetsAfter < minExpected) {
            revert SlippageExceededDetailed(totalAssetsBefore, totalAssetsAfter, maxSlippage);
        }

        // Update timestamp
        s.rebalanceConfig.lastRebalanceTime = block.timestamp;

        // Get new allocations for event
        uint256[] memory newAllocations = new uint256[](vaults.length);
        for (uint256 i = 0; i < vaults.length; ) {
            newAllocations[i] = LibNexusVault.assetsInVault(vaults[i]);
            unchecked {
                ++i;
            }
        }

        emit Rebalanced(
            block.timestamp,
            totalAssetsAfter,
            vaults,
            oldAllocations,
            newAllocations
        );
    }

    /**
     * @notice Force rebalance ignoring cooldown (emergency use)
     * @dev Only callable by admin or owner
     */
    function forceRebalance() external nonReentrant {
        LibNexusVaultAuth.enforceIsAdmin();
        LibNexusVaultAuth.enforceOperational();

        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        uint256 totalAssetsBefore = LibNexusVault.totalAssets();
        if (totalAssetsBefore == 0) revert ZeroAmount();

        uint256 activeCount = s.activeVaultCount;
        if (activeCount == 0) revert NoActiveVaults();

        (
            address[] memory vaults,
            uint256[] memory oldAllocations,
            ,
            int256[] memory deltas
        ) = _calculateRebalanceDeltas(totalAssetsBefore);

        _executeRebalance(vaults, deltas);

        s.rebalanceConfig.lastRebalanceTime = block.timestamp;

        uint256[] memory newAllocations = new uint256[](vaults.length);
        for (uint256 i = 0; i < vaults.length; ) {
            newAllocations[i] = LibNexusVault.assetsInVault(vaults[i]);
            unchecked {
                ++i;
            }
        }

        emit Rebalanced(
            block.timestamp,
            LibNexusVault.totalAssets(),
            vaults,
            oldAllocations,
            newAllocations
        );
    }

    /*//////////////////////////////////////////////////////////////
                            FEE COLLECTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Collect pending management fee
     * @dev Mints fee as shares to fee recipient
     *      Callable by keepers, admin, or owner
     * @return feeShares Shares minted as fee
     */
    function collectManagementFee() external nonReentrant returns (uint256 feeShares) {
        LibNexusVaultAuth.enforceIsKeeper();

        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        uint256 feeAmount;
        (feeAmount, feeShares) = LibNexusVault.calculateManagementFee();

        if (feeShares == 0) return 0;

        address recipient = s.feeConfig.feeRecipient;
        if (recipient == address(0)) revert InvalidFeeRecipient();

        // Mint fee shares to recipient
        _mint(recipient, feeShares);

        // Update timestamp
        s.lastFeeTimestamp = block.timestamp;

        emit ManagementFeeCollected(feeAmount, feeShares, recipient);
    }

    /**
     * @notice Collect pending performance fee
     * @dev Only collects if current assets exceed high water mark
     *      Updates high water mark after collection
     * @return feeShares Shares minted as fee
     */
    function collectPerformanceFee() external nonReentrant returns (uint256 feeShares) {
        LibNexusVaultAuth.enforceIsKeeper();

        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        uint256 feeAmount;
        uint256 newHwm;
        (feeAmount, feeShares, newHwm) = LibNexusVault.calculatePerformanceFee();

        if (feeShares == 0) return 0;

        address recipient = s.feeConfig.feeRecipient;
        if (recipient == address(0)) revert InvalidFeeRecipient();

        // Mint fee shares to recipient
        _mint(recipient, feeShares);

        // Update high water mark
        s.highWaterMark = newHwm;

        emit PerformanceFeeCollected(feeAmount, feeShares, newHwm, recipient);
    }

    /**
     * @notice Collect all pending fees
     * @dev Convenience function to collect both fees at once
     * @return managementFeeShares Management fee shares minted
     * @return performanceFeeShares Performance fee shares minted
     */
    function collectAllFees()
        external
        nonReentrant
        returns (uint256 managementFeeShares, uint256 performanceFeeShares)
    {
        LibNexusVaultAuth.enforceIsKeeper();

        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();
        address recipient = s.feeConfig.feeRecipient;
        if (recipient == address(0)) revert InvalidFeeRecipient();

        // Collect management fee
        uint256 mgmtFeeAmount;
        (mgmtFeeAmount, managementFeeShares) = LibNexusVault.calculateManagementFee();

        if (managementFeeShares > 0) {
            _mint(recipient, managementFeeShares);
            s.lastFeeTimestamp = block.timestamp;
            emit ManagementFeeCollected(mgmtFeeAmount, managementFeeShares, recipient);
        }

        // Collect performance fee
        uint256 perfFeeAmount;
        uint256 newHwm;
        (perfFeeAmount, performanceFeeShares, newHwm) =
            LibNexusVault.calculatePerformanceFee();

        if (performanceFeeShares > 0) {
            _mint(recipient, performanceFeeShares);
            s.highWaterMark = newHwm;
            emit PerformanceFeeCollected(
                perfFeeAmount,
                performanceFeeShares,
                newHwm,
                recipient
            );
        }
    }

    /**
     * @notice Reset high water mark to current assets
     * @dev Only callable by owner, use with caution
     */
    function resetHighWaterMark() external {
        LibNexusVaultAuth.enforceIsOwner();

        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();
        uint256 newHwm = LibNexusVault.totalAssets();
        s.highWaterMark = newHwm;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculate deltas for each vault
     * @param totalAssetsBefore Total assets before rebalance
     * @return vaults Active vault addresses
     * @return oldAllocations Current asset allocations
     * @return targetAllocations Target asset allocations
     * @return deltas Change needed (positive = deposit, negative = withdraw)
     */
    function _calculateRebalanceDeltas(
        uint256 totalAssetsBefore
    )
        internal
        view
        returns (
            address[] memory vaults,
            uint256[] memory oldAllocations,
            uint256[] memory targetAllocations,
            int256[] memory deltas
        )
    {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        uint256 activeCount = s.activeVaultCount;
        vaults = new address[](activeCount);
        oldAllocations = new uint256[](activeCount);
        targetAllocations = new uint256[](activeCount);
        deltas = new int256[](activeCount);

        // Calculate total target weight for normalization
        uint256 totalWeight = 0;
        address[] storage vaultList = s.vaultList;
        uint256 length = vaultList.length;
        uint256 idx = 0;

        for (uint256 i = 0; i < length; ) {
            address vault = vaultList[i];
            if (s.vaultConfigs[vault].isActive) {
                vaults[idx] = vault;
                oldAllocations[idx] = LibNexusVault.assetsInVault(vault);
                totalWeight += s.vaultConfigs[vault].targetWeight;
                idx++;
            }
            unchecked {
                ++i;
            }
        }

        // Calculate target allocations and deltas
        // Note: We use totalAssetsBefore minus idle for vault allocation
        // Idle assets are included in rebalance
        uint256 assetsToAllocate = totalAssetsBefore;

        for (uint256 i = 0; i < activeCount; ) {
            if (totalWeight > 0) {
                targetAllocations[i] = assetsToAllocate.mulDiv(
                    s.vaultConfigs[vaults[i]].targetWeight,
                    totalWeight
                );
            }
            deltas[i] = int256(targetAllocations[i]) - int256(oldAllocations[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Execute the rebalance transfers
     * @param vaults Vault addresses
     * @param deltas Changes for each vault
     */
    function _executeRebalance(
        address[] memory vaults,
        int256[] memory deltas
    ) internal {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();
        IERC20 asset = s.asset;
        uint256 length = vaults.length;

        // First pass: withdraw from over-allocated vaults
        for (uint256 i = 0; i < length; ) {
            if (deltas[i] < 0) {
                uint256 withdrawAmount = uint256(-deltas[i]);
                IERC4626(vaults[i]).withdraw(withdrawAmount, address(this), address(this));
            }
            unchecked {
                ++i;
            }
        }

        // Second pass: deposit to under-allocated vaults
        for (uint256 i = 0; i < length; ) {
            if (deltas[i] > 0) {
                uint256 depositAmount = uint256(deltas[i]);
                asset.forceApprove(vaults[i], depositAmount);
                IERC4626(vaults[i]).deposit(depositAmount, address(this));
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Mint shares to an address
     * @param to Recipient address
     * @param amount Amount of shares to mint
     */
    function _mint(address to, uint256 amount) internal {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        s.totalSupply += amount;
        unchecked {
            s.balances[to] += amount;
        }

        emit Transfer(address(0), to, amount);
    }
}
