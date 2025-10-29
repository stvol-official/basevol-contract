// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IGenesisStrategy } from "../../core/vault/interfaces/IGenesisStrategy.sol";

/**
 * @title LibGenesisVaultStorage
 * @notice Diamond Storage for GenesisVault
 * @dev Uses Diamond Storage pattern to avoid storage collisions
 */
library LibGenesisVaultStorage {
  // keccak256("genesis.vault.diamond.storage") - 1
  bytes32 constant DIAMOND_STORAGE_POSITION = keccak256("genesis.vault.diamond.storage");

  /**
   * @notice Round settlement data for epoch-based operations
   */
  struct RoundData {
    // Request data
    uint256 totalRequestedDepositAssets; // Total assets requested for deposit during this epoch
    uint256 claimedDepositAssets; // Deposit assets that have been claimed by users
    uint256 totalRequestedRedeemShares; // Total shares requested for redemption during this epoch
    uint256 claimedRedeemShares; // Redeem shares that have been claimed by users
    // Settlement data
    uint256 sharePrice; // Share price when this epoch was settled (scaled by 1e18)
    bool isSettled; // Whether this epoch has been settled
    uint256 settlementTimestamp; // Timestamp when settlement occurred
  }

  /**
   * @notice User performance tracking for WAEP-based fee calculation
   */
  struct UserPerformanceData {
    uint256 waep; // Weighted Average Entry Price (scaled by 1e18)
    uint256 totalShares; // Total shares owned by the user
    uint256 lastUpdateEpoch; // Last epoch when this data was updated
  }

  /**
   * @notice Management fee tracking data
   */
  struct ManagementFeeData {
    uint256 lastFeeTimestamp; // Last timestamp when management fee was charged
    uint256 totalFeesCollected; // Total management fees collected (in shares)
  }

  /**
   * @notice Main Diamond Storage layout
   * @dev All state variables for GenesisVault Diamond
   */
  struct Layout {
    // ============ Core Vault State ============
    IERC20 asset; // Underlying asset (e.g., USDC)
    string name; // Vault name
    string symbol; // Vault symbol
    uint8 decimals; // Decimals (cached from asset during initialization)
    uint256 totalSupply; // Total shares supply
    mapping(address => uint256) balances; // User share balances
    mapping(address => mapping(address => uint256)) allowances; // ERC20 allowances
    // ============ Access Control ============
    address owner; // Contract owner
    address admin; // Admin address
    address[] keepers; // List of keeper addresses authorized to call settlement functions
    // ============ Integration Addresses ============
    address baseVolContract; // BaseVol contract address for settlement callbacks
    address strategy; // Strategy contract address
    // ============ ERC7540 Operator System ============
    mapping(address => mapping(address => bool)) operators; // ERC7540 operator approvals
    // ============ Round/Epoch Management ============
    mapping(uint256 => RoundData) roundData; // Round-based integrated deposit/redeem data
    // ============ Deposit Tracking (epoch-based) ============
    mapping(address => mapping(uint256 => uint256)) userEpochDepositAssets; // User's deposited assets per epoch
    mapping(address => mapping(uint256 => uint256)) userEpochClaimedDepositAssets; // User's claimed deposit assets per epoch
    mapping(address => uint256[]) userDepositEpochs; // List of epochs where user made deposits
    // ============ Redeem Tracking (epoch-based) ============
    mapping(address => mapping(uint256 => uint256)) userEpochRedeemShares; // User's redeemed shares per epoch
    mapping(address => mapping(uint256 => uint256)) userEpochClaimedRedeemShares; // User's claimed redeem shares per epoch
    mapping(address => uint256[]) userRedeemEpochs; // List of epochs where user made redemptions
    // ============ Auto-Processing Tracking ============
    mapping(uint256 => address[]) epochDepositUsers; // List of users who made deposit requests in each epoch
    mapping(uint256 => address[]) epochRedeemUsers; // List of users who made redeem requests in each epoch
    // ============ Fee Management ============
    uint256 managementFee; // Annual management fee (e.g., 200 = 2%)
    uint256 performanceFee; // Performance fee on profits (e.g., 2000 = 20%)
    uint256 hurdleRate; // Minimum return before performance fee applies
    uint256 entryCost; // Fixed entry cost in asset units
    uint256 exitCost; // Fixed exit cost in asset units
    address feeRecipient; // Address to receive all fees
    // ============ User Performance Tracking (for WAEP) ============
    mapping(address => UserPerformanceData) userPerformanceData; // User-based performance fee tracking
    ManagementFeeData managementFeeData; // Management fee data
    // ============ Limits & Controls ============
    uint256 userDepositLimit; // Maximum deposit per user
    uint256 vaultDepositLimit; // Maximum total deposits for vault
    bool shutdown; // Vault shutdown state
    bool paused; // Vault paused state
    address clearingHouse; // ClearingHouse contract address authorized for direct deposits

    /* IMPORTANT: Add new variables here to maintain storage layout */
  }

  /**
   * @notice Returns the Diamond Storage
   * @return ds The Diamond Storage layout
   */
  function layout() internal pure returns (Layout storage ds) {
    bytes32 position = DIAMOND_STORAGE_POSITION;
    assembly {
      ds.slot := position
    }
  }
}
