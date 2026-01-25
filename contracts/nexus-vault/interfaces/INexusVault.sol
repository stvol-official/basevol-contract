// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title INexusVault
 * @author BaseVol Team
 * @notice Interface for NexusVault - Multi-Vault ERC4626 Aggregator
 * @dev Extends ERC4626 with multi-vault management and rebalancing capabilities
 */
interface INexusVault is IERC4626 {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new underlying vault is added
    event VaultAdded(
        address indexed vault,
        uint256 targetWeight,
        uint256 maxWeight,
        uint256 minWeight
    );

    /// @notice Emitted when a vault is removed
    event VaultRemoved(address indexed vault);

    /// @notice Emitted when a vault's target weight is updated
    event VaultWeightUpdated(
        address indexed vault,
        uint256 oldWeight,
        uint256 newWeight
    );

    /// @notice Emitted when a vault is activated
    event VaultActivated(address indexed vault);

    /// @notice Emitted when a vault is deactivated
    event VaultDeactivated(address indexed vault);

    /// @notice Emitted when rebalancing is executed
    event Rebalanced(
        uint256 indexed timestamp,
        uint256 totalAssets,
        address[] vaults,
        uint256[] oldAllocations,
        uint256[] newAllocations
    );

    /// @notice Emitted when partial rebalancing is executed
    event PartialRebalance(
        address indexed fromVault,
        address indexed toVault,
        uint256 amount
    );

    /// @notice Emitted when management fees are collected
    event ManagementFeeCollected(
        uint256 feeAmount,
        uint256 feeShares,
        uint256 timestamp
    );

    /// @notice Emitted when performance fees are collected
    event PerformanceFeeCollected(
        uint256 feeAmount,
        uint256 feeShares,
        uint256 newHighWaterMark
    );

    /// @notice Emitted when all fees are collected
    event FeesCollected(
        address indexed recipient,
        uint256 managementFee,
        uint256 performanceFee,
        uint256 totalShares
    );

    /// @notice Emitted when fee configuration is updated
    event FeeConfigUpdated(
        uint256 managementFee,
        uint256 performanceFee,
        uint256 depositFee,
        uint256 withdrawFee
    );

    /// @notice Emitted when fee recipient is updated
    event FeeRecipientUpdated(
        address indexed oldRecipient,
        address indexed newRecipient
    );

    /// @notice Emitted when deposit caps are updated
    event DepositCapsUpdated(uint256 totalCap, uint256 userCap);

    /// @notice Emitted when rebalance configuration is updated
    event RebalanceConfigUpdated(
        uint256 threshold,
        uint256 maxSlippage,
        uint256 cooldownPeriod
    );

    /// @notice Emitted when vault is paused
    event Paused(address indexed account);

    /// @notice Emitted when vault is unpaused
    event Unpaused(address indexed account);

    /// @notice Emitted when vault is permanently shutdown
    event Shutdown(address indexed account);

    /// @notice Emitted on emergency withdrawal from underlying vault
    event EmergencyWithdraw(address indexed vault, uint256 amount);

    /// @notice Emitted when admin is updated
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);

    /// @notice Emitted when a keeper is added
    event KeeperAdded(address indexed keeper);

    /// @notice Emitted when a keeper is removed
    event KeeperRemoved(address indexed keeper);

    /*//////////////////////////////////////////////////////////////
                            VAULT MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Add a new underlying ERC4626 vault
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
    ) external;

    /**
     * @notice Remove an underlying vault (must be empty)
     * @param vault Vault address to remove
     */
    function removeVault(address vault) external;

    /**
     * @notice Update target weight for a vault
     * @param vault Vault address to update
     * @param newWeight New target weight
     */
    function setVaultWeight(address vault, uint256 newWeight) external;

    /**
     * @notice Update weights for multiple vaults at once
     * @param vaults Array of vault addresses
     * @param newWeights Array of new weights (must sum to 1e18)
     */
    function setVaultWeights(
        address[] calldata vaults,
        uint256[] calldata newWeights
    ) external;

    /**
     * @notice Activate or deactivate a vault
     * @param vault Vault address
     * @param active New active status
     */
    function setVaultActive(address vault, bool active) external;

    /**
     * @notice Get all registered vault addresses
     * @return Array of vault addresses
     */
    function getVaults() external view returns (address[] memory);

    /**
     * @notice Get only active vault addresses
     * @return Array of active vault addresses
     */
    function getActiveVaults() external view returns (address[] memory);

    /**
     * @notice Get configuration for a specific vault
     * @param vault Vault address to query
     * @return targetWeight Target allocation weight
     * @return currentWeight Current allocation weight
     * @return assets Current assets in this vault
     * @return isActive Whether vault is active
     */
    function getVaultConfig(
        address vault
    )
        external
        view
        returns (
            uint256 targetWeight,
            uint256 currentWeight,
            uint256 assets,
            bool isActive
        );

    /*//////////////////////////////////////////////////////////////
                            REBALANCING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute full portfolio rebalancing
     * @dev Only callable by keepers
     */
    function rebalance() external;

    /**
     * @notice Execute partial rebalancing between two vaults
     * @param fromVault Source vault (over-allocated)
     * @param toVault Destination vault (under-allocated)
     * @param amount Amount to transfer
     */
    function partialRebalance(
        address fromVault,
        address toVault,
        uint256 amount
    ) external;

    /**
     * @notice Check if rebalancing is needed
     * @return True if any vault exceeds deviation threshold
     */
    function needsRebalance() external view returns (bool);

    /**
     * @notice Get current allocation status for all vaults
     * @return vaults Array of vault addresses
     * @return currentWeights Current allocation weights
     * @return targetWeights Target allocation weights
     * @return deviations Deviation from target (positive = over, negative = under)
     */
    function getAllocationStatus()
        external
        view
        returns (
            address[] memory vaults,
            uint256[] memory currentWeights,
            uint256[] memory targetWeights,
            int256[] memory deviations
        );

    /*//////////////////////////////////////////////////////////////
                            NEXUS-SPECIFIC VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get assets deployed in a specific underlying vault
     * @param vault Vault address to query
     * @return Assets withdrawable from this vault
     */
    function assetsInVault(address vault) external view returns (uint256);

    /**
     * @notice Get idle assets not deployed to any vault
     * @return Idle asset balance
     */
    function idleAssets() external view returns (uint256);

    /**
     * @notice Get total count of registered vaults
     * @return Number of vaults
     */
    function vaultCount() external view returns (uint256);

    /**
     * @notice Get count of active vaults
     * @return Number of active vaults
     */
    function activeVaultCount() external view returns (uint256);

    /**
     * @notice Get pending fees to be collected
     * @return managementFee Pending management fee
     * @return performanceFee Pending performance fee
     */
    function pendingFees()
        external
        view
        returns (uint256 managementFee, uint256 performanceFee);

    /**
     * @notice Get fee configuration
     * @return managementFee Annual management fee
     * @return performanceFee Performance fee on profits
     * @return depositFee Deposit fee
     * @return withdrawFee Withdrawal fee
     * @return feeRecipient Fee recipient address
     */
    function getFeeConfig()
        external
        view
        returns (
            uint256 managementFee,
            uint256 performanceFee,
            uint256 depositFee,
            uint256 withdrawFee,
            address feeRecipient
        );

    /**
     * @notice Get rebalance configuration
     * @return threshold Deviation threshold
     * @return maxSlippage Maximum slippage
     * @return cooldownPeriod Cooldown period
     * @return lastRebalanceTime Last rebalance timestamp
     */
    function getRebalanceConfig()
        external
        view
        returns (
            uint256 threshold,
            uint256 maxSlippage,
            uint256 cooldownPeriod,
            uint256 lastRebalanceTime
        );

    /**
     * @notice Get deposit caps
     * @return totalCap Maximum total deposits
     * @return userCap Maximum per-user deposits
     */
    function getDepositCaps()
        external
        view
        returns (uint256 totalCap, uint256 userCap);

    /**
     * @notice Check if vault is paused
     * @return True if paused
     */
    function paused() external view returns (bool);

    /**
     * @notice Check if vault is shutdown
     * @return True if shutdown
     */
    function isShutdown() external view returns (bool);

    /**
     * @notice Get admin address
     * @return Admin address
     */
    function admin() external view returns (address);

    /**
     * @notice Get list of keepers
     * @return Array of keeper addresses
     */
    function getKeepers() external view returns (address[] memory);

    /**
     * @notice Check if address is a keeper
     * @param account Address to check
     * @return True if keeper
     */
    function isKeeper(address account) external view returns (bool);
}
