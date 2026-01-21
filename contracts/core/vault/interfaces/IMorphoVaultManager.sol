// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @title IMorphoVaultManager Interface
/// @author BaseVol Team
/// @notice Interface for MorphoVaultManager contract that handles Morpho Vault interactions
/// @dev Supports both single-vault and multi-vault modes
interface IMorphoVaultManager {
  /*//////////////////////////////////////////////////////////////
                              STRUCTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Vault info returned by view functions
  struct VaultInfo {
    address vault;
    uint256 weightBps;
    uint256 shares;
    uint256 assetBalance;
    uint256 deposited;
    uint256 withdrawn;
    bool isActive;
  }

  /// @notice Allocation status for rebalancing decisions
  struct AllocationStatus {
    uint256 vaultIndex;
    address vault;
    uint256 currentBps; // Current allocation in bps
    uint256 targetBps; // Target allocation in bps
    int256 deviationBps; // Deviation from target (positive = over-allocated)
    uint256 currentAssets;
    uint256 targetAssets;
  }

  /*//////////////////////////////////////////////////////////////
                              EVENTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Emitted when multi-vault mode is enabled
  event MultiVaultEnabled(uint256 primaryVaultWeightBps, uint256 timestamp);

  /// @notice Emitted when multi-vault mode is disabled
  event MultiVaultDisabled(uint256 timestamp);

  /// @notice Emitted when a vault is added
  event VaultAdded(
    uint256 indexed vaultIndex,
    address indexed vault,
    uint256 weightBps,
    uint256 timestamp
  );

  /// @notice Emitted when a vault is deactivated
  event VaultDeactivated(uint256 indexed vaultIndex, address indexed vault, uint256 timestamp);

  /// @notice Emitted when a vault is reactivated
  event VaultReactivated(uint256 indexed vaultIndex, address indexed vault, uint256 timestamp);

  /// @notice Emitted when vault weight is updated
  event VaultWeightUpdated(
    uint256 indexed vaultIndex,
    address indexed vault,
    uint256 oldWeightBps,
    uint256 newWeightBps,
    uint256 timestamp
  );

  /// @notice Emitted when deposit is made to a specific vault
  event DepositedToVault(
    uint256 indexed vaultIndex,
    address indexed vault,
    uint256 amount,
    uint256 shares,
    uint256 timestamp
  );

  /// @notice Emitted when withdrawal is made from a specific vault
  event WithdrawnFromVault(
    uint256 indexed vaultIndex,
    address indexed vault,
    uint256 amount,
    uint256 shares,
    uint256 timestamp
  );

  /// @notice Emitted when rebalance is performed
  event Rebalanced(
    uint256 totalAssetsMoved,
    uint256 vaultsAffected,
    uint256 timestamp
  );

  /// @notice Emitted when rebalance threshold is updated
  event RebalanceThresholdUpdated(uint256 oldThresholdBps, uint256 newThresholdBps);

  /*//////////////////////////////////////////////////////////////
                              ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when multi-vault mode is not enabled
  error MultiVaultNotEnabled();

  /// @notice Thrown when multi-vault mode is already enabled
  error MultiVaultAlreadyEnabled();

  /// @notice Thrown when vault is already added
  error VaultAlreadyExists(address vault);

  /// @notice Thrown when vault is not found
  error VaultNotFound(uint256 vaultIndex);

  /// @notice Thrown when trying to deactivate primary vault
  error CannotDeactivatePrimaryVault();

  /// @notice Thrown when vault is already inactive
  error VaultAlreadyInactive(uint256 vaultIndex);

  /// @notice Thrown when vault is already active
  error VaultAlreadyActive(uint256 vaultIndex);

  /// @notice Thrown when max vaults limit reached
  error MaxVaultsReached(uint256 maxVaults);

  /// @notice Thrown when weight is invalid (zero)
  error InvalidWeight(uint256 weight);

  /// @notice Thrown when asset mismatch between vaults
  error AssetMismatch(address expected, address actual);

  /// @notice Thrown when rebalance threshold is invalid
  error InvalidRebalanceThreshold(uint256 threshold);

  /// @notice Thrown when nothing to rebalance
  error NothingToRebalance();

  /*//////////////////////////////////////////////////////////////
                        CORE FUNCTIONS (EXISTING)
  //////////////////////////////////////////////////////////////*/

  /// @notice Deposits assets to Morpho Vault(s)
  /// @dev In multi-vault mode, distributes according to weight allocation
  /// @param amount The amount of assets to deposit
  function depositToMorpho(uint256 amount) external;

  /// @notice Withdraws assets from Morpho Vault(s)
  /// @dev In multi-vault mode, withdraws proportionally from all vaults
  /// @param amount The amount of assets to withdraw
  function withdrawFromMorpho(uint256 amount) external;

  /// @notice Redeems shares from Morpho Vault
  /// @dev Only works in single-vault mode or for primary vault
  /// @param shares The amount of shares to redeem
  function redeemFromMorpho(uint256 shares) external;

  /*//////////////////////////////////////////////////////////////
                      MULTI-VAULT ADMIN FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Enables multi-vault mode with primary vault weight
  /// @param primaryWeightBps Weight for primary vault in basis points (e.g., 3000 = 30%)
  function enableMultiVault(uint256 primaryWeightBps) external;

  /// @notice Disables multi-vault mode (requires all additional vaults to be empty)
  function disableMultiVault() external;

  /// @notice Adds a new vault to the allocation
  /// @param vault The Morpho Vault address
  /// @param weightBps The allocation weight in basis points
  function addVault(address vault, uint256 weightBps) external;

  /// @notice Deactivates a vault (prevents new deposits, can still withdraw)
  /// @param vaultIndex The index of the vault (1+ for additional vaults)
  function deactivateVault(uint256 vaultIndex) external;

  /// @notice Reactivates a previously deactivated vault
  /// @param vaultIndex The index of the vault
  function reactivateVault(uint256 vaultIndex) external;

  /// @notice Updates the weight of a vault
  /// @param vaultIndex The index of the vault (0 = primary, 1+ = additional)
  /// @param newWeightBps The new weight in basis points
  function updateVaultWeight(uint256 vaultIndex, uint256 newWeightBps) external;

  /// @notice Updates weights for multiple vaults at once
  /// @param vaultIndices Array of vault indices
  /// @param newWeightsBps Array of new weights in basis points
  function batchUpdateVaultWeights(
    uint256[] calldata vaultIndices,
    uint256[] calldata newWeightsBps
  ) external;

  /// @notice Sets the rebalance threshold
  /// @param thresholdBps New threshold in basis points
  function setRebalanceThreshold(uint256 thresholdBps) external;

  /*//////////////////////////////////////////////////////////////
                        REBALANCING FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Rebalances assets across vaults to match target allocations
  function rebalance() external;

  /// @notice Withdraws all assets from a specific vault (for migration/deactivation)
  /// @param vaultIndex The index of the vault to empty
  function withdrawAllFromVault(uint256 vaultIndex) external;

  /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Gets the Morpho Vault balance in assets (total across all vaults)
  /// @return The total asset balance across all Morpho Vaults
  function morphoAssetBalance() external view returns (uint256);

  /// @notice Gets the Morpho Vault balance in shares (primary vault only for compatibility)
  /// @return The share balance in the primary Morpho Vault
  function morphoShareBalance() external view returns (uint256);

  /// @notice Gets the total deposited amount
  /// @return The total deposited amount
  function totalDeposited() external view returns (uint256);

  /// @notice Gets the total withdrawn amount
  /// @return The total withdrawn amount
  function totalWithdrawn() external view returns (uint256);

  /// @notice Gets the total utilized amount
  /// @return The total utilized amount
  function totalUtilized() external view returns (uint256);

  /// @notice Gets the current yield/profit from Morpho
  /// @return The accumulated yield
  function currentYield() external view returns (uint256);

  /// @notice Gets the configuration
  /// @return maxStrategyDeposit The maximum deposit amount
  /// @return minStrategyDeposit The minimum deposit amount
  function config() external view returns (uint256 maxStrategyDeposit, uint256 minStrategyDeposit);

  /// @notice Checks if multi-vault mode is enabled
  /// @return True if multi-vault mode is enabled
  function isMultiVaultEnabled() external view returns (bool);

  /// @notice Gets the total number of vaults (primary + additional)
  /// @return Total number of vaults
  function getVaultCount() external view returns (uint256);

  /// @notice Gets the number of active vaults
  /// @return Number of active vaults
  function getActiveVaultCount() external view returns (uint256);

  /// @notice Gets info for a specific vault
  /// @param vaultIndex 0 = primary, 1+ = additional
  /// @return info The vault information
  function getVaultInfo(uint256 vaultIndex) external view returns (VaultInfo memory info);

  /// @notice Gets info for all vaults
  /// @return infos Array of vault information
  function getAllVaultInfos() external view returns (VaultInfo[] memory infos);

  /// @notice Gets the current allocation status for all vaults
  /// @return statuses Array of allocation statuses
  function getAllocationStatus() external view returns (AllocationStatus[] memory statuses);

  /// @notice Checks if rebalance is needed based on threshold
  /// @return needed Whether rebalance is needed
  /// @return maxDeviationBps Maximum deviation from target in bps
  function isRebalanceNeeded() external view returns (bool needed, uint256 maxDeviationBps);

  /// @notice Gets the total weight of all active vaults
  /// @return Total weight in basis points
  function getTotalWeightBps() external view returns (uint256);

  /// @notice Gets the rebalance threshold
  /// @return Threshold in basis points
  function getRebalanceThreshold() external view returns (uint256);

  /// @notice Gets the last rebalance timestamp
  /// @return Timestamp of last rebalance
  function getLastRebalanceTimestamp() external view returns (uint256);
}
