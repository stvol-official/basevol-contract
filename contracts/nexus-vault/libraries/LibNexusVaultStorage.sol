// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title LibNexusVaultStorage
 * @author BaseVol Team
 * @notice Diamond Storage for NexusVault - ERC4626 Multi-Vault Aggregator
 * @dev Uses Diamond Storage pattern (EIP-2535) to avoid storage collisions between facets.
 *
 * CRITICAL STORAGE RULES:
 * 1. NEVER modify the order of existing variables
 * 2. NEVER change the types of existing variables
 * 3. NEVER remove existing variables
 * 4. ALWAYS append new variables at the end of the Layout struct
 * 5. Mark deprecated variables with comments instead of removing them
 */
library LibNexusVaultStorage {
    /// @dev keccak256("nexus.vault.diamond.storage")
    bytes32 internal constant DIAMOND_STORAGE_POSITION =
        keccak256("nexus.vault.diamond.storage");

    /*//////////////////////////////////////////////////////////////
                            STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Configuration for an underlying ERC4626 vault
     * @param vault The ERC4626 vault address
     * @param targetWeight Target allocation weight (1e18 = 100%)
     * @param maxWeight Maximum allowed weight for slippage control
     * @param minWeight Minimum allowed weight for slippage control
     * @param isActive Whether this vault is currently active for deposits
     * @param depositCap Maximum deposit allowed to this vault (0 = unlimited)
     */
    struct VaultConfig {
        address vault;
        uint256 targetWeight;
        uint256 maxWeight;
        uint256 minWeight;
        bool isActive;
        uint256 depositCap;
    }

    /**
     * @notice Fee configuration for the vault
     * @param managementFee Annual management fee (1e18 = 100%, e.g., 0.02e18 = 2%)
     * @param performanceFee Fee on profits above high water mark (1e18 = 100%)
     * @param depositFee One-time fee on deposits (1e18 = 100%)
     * @param withdrawFee One-time fee on withdrawals (1e18 = 100%)
     * @param feeRecipient Address that receives all fees
     */
    struct FeeConfig {
        uint256 managementFee;
        uint256 performanceFee;
        uint256 depositFee;
        uint256 withdrawFee;
        address feeRecipient;
    }

    /**
     * @notice Configuration for automatic rebalancing
     * @param rebalanceThreshold Minimum deviation to trigger rebalance (1e18 = 100%)
     * @param maxSlippage Maximum slippage allowed during rebalance (1e18 = 100%)
     * @param cooldownPeriod Minimum seconds between rebalances
     * @param lastRebalanceTime Timestamp of last successful rebalance
     */
    struct RebalanceConfig {
        uint256 rebalanceThreshold;
        uint256 maxSlippage;
        uint256 cooldownPeriod;
        uint256 lastRebalanceTime;
    }

    /**
     * @notice Main Diamond Storage layout for NexusVault
     * @dev All state variables for the NexusVault Diamond
     *
     * Storage Layout (slot allocation for reference):
     * - Slots 0-6: Core ERC20/ERC4626 state
     * - Slots 7-9: Access control
     * - Slots 10-14: Vault registry
     * - Slots 15-17: Fee management
     * - Slots 18: Rebalancing config
     * - Slots 19-23: Limits and controls
     * - Slots 24+: Reserved for future upgrades
     */
    struct Layout {
        // ============ Core Vault State (ERC20/ERC4626) ============
        /// @dev The underlying asset token (e.g., USDC)
        IERC20 asset;
        /// @dev Vault token name
        string name;
        /// @dev Vault token symbol
        string symbol;
        /// @dev Decimals (cached from asset during initialization)
        uint8 decimals;
        /// @dev Total supply of vault shares
        uint256 totalSupply;
        /// @dev User share balances: user => balance
        mapping(address => uint256) balances;
        /// @dev ERC20 allowances: owner => spender => amount
        mapping(address => mapping(address => uint256)) allowances;
        // ============ Access Control ============
        /// @dev Diamond contract owner (can upgrade diamond, set admin)
        address owner;
        /// @dev Admin address (can configure vaults, fees, keepers)
        address admin;
        /// @dev List of keeper addresses authorized for rebalancing and fee collection
        address[] keepers;
        // ============ Vault Registry ============
        /// @dev Ordered list of underlying vault addresses
        address[] vaultList;
        /// @dev Configuration for each vault: vault address => config
        mapping(address => VaultConfig) vaultConfigs;
        /// @dev Index lookup for vault removal: vault address => index+1 (0 means not exists)
        mapping(address => uint256) vaultIndexes;
        /// @dev Count of currently active vaults
        uint256 activeVaultCount;
        // ============ Fee Management ============
        /// @dev Fee configuration struct
        FeeConfig feeConfig;
        /// @dev Timestamp when fees were last collected
        uint256 lastFeeTimestamp;
        /// @dev High water mark for performance fee calculation
        uint256 highWaterMark;
        // ============ Rebalancing ============
        /// @dev Rebalancing configuration struct
        RebalanceConfig rebalanceConfig;
        // ============ Limits & Controls ============
        /// @dev Maximum total assets allowed in vault (0 = unlimited)
        uint256 totalDepositCap;
        /// @dev Maximum assets per user (0 = unlimited)
        uint256 userDepositCap;
        /// @dev Emergency pause state - blocks all operations
        bool paused;
        /// @dev Permanent shutdown state - allows only withdrawals
        bool shutdown;
        // ============ Performance Tracking ============
        /// @dev Historical total deposits for analytics
        uint256 totalDeposited;
        /// @dev Historical total withdrawals for analytics
        uint256 totalWithdrawn;
        // ============ Reentrancy Guard ============
        /// @dev Reentrancy status: 1 = not entered, 2 = entered
        uint256 reentrancyStatus;
    }

    /*
     * IMPORTANT: Add new storage variables below this line.
     * Never modify anything above this comment.
     *
     * Example:
     * /// @dev New feature flag added in v1.1
     * bool newFeatureEnabled;
     */

    /*//////////////////////////////////////////////////////////////
                            STORAGE ACCESS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the Diamond Storage layout
     * @dev Uses assembly to access storage at a fixed position
     * @return ds The storage layout struct
     */
    function layout() internal pure returns (Layout storage ds) {
        bytes32 position = DIAMOND_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }
}
