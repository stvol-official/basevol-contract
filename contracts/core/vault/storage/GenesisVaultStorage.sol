// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library GenesisVaultStorage {
  // keccak256(abi.encode(uint256(keccak256("com.basevol.storage.genesisvault")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 internal constant SLOT =
    0x5ee42217d3eb996ad2b1dbf985c1bba88b7a17b6b441c8b6deb9a267d873da00;

  // Note: Individual request structs removed since requestId = epoch
  // All request data is now tracked in epoch-based mappings

  struct EpochData {
    // Request data
    /// @dev Total assets requested for deposit during this epoch
    uint256 totalRequestedDepositAssets;
    /// @dev Deposit assets that have been claimed by users
    uint256 claimedDepositAssets;
    /// @dev Total shares requested for redemption during this epoch
    uint256 totalRequestedRedeemShares;
    /// @dev Redeem shares that have been claimed by users
    uint256 claimedRedeemShares;
    // Settlement data
    /// @dev Share price when this epoch was settled (scaled by share decimals precision)
    uint256 sharePrice;
    /// @dev Whether this epoch has been settled by BaseVol (when true, all requests become claimable)
    bool isSettled;
    /// @dev Timestamp when settlement occurred
    uint256 settlementTimestamp;
  }

  struct Layout {
    /// @dev BaseVol contract address for settlement callbacks
    address baseVolContract;
    address strategy;
    uint256 entryCost;
    uint256 exitCost;
    address[] prioritizedAccounts;
    bool shutdown;
    // Note: nextRequestId, depositRequests, redeemRequests removed
    // ERC7540: requestId = epoch for fungibility and simplicity
    // ERC7540 operator system
    mapping(address => mapping(address => bool)) operators;
    // Epoch-based data management
    /// @dev Epoch-based integrated deposit/redeem data storage
    mapping(uint256 => EpochData) epochData;
    // Deposit tracking
    /// @dev User's deposited assets per epoch
    mapping(address => mapping(uint256 => uint256)) userEpochDepositAssets;
    /// @dev User's claimed deposit assets per epoch
    mapping(address => mapping(uint256 => uint256)) userEpochClaimedDepositAssets;
    /// @dev List of epochs where user made deposits
    mapping(address => uint256[]) userDepositEpochs;
    // Redeem tracking
    /// @dev User's redeemed shares per epoch
    mapping(address => mapping(uint256 => uint256)) userEpochRedeemShares;
    /// @dev User's claimed redeem shares per epoch
    mapping(address => mapping(uint256 => uint256)) userEpochClaimedRedeemShares;
    /// @dev List of epochs where user made redemptions
    mapping(address => uint256[]) userRedeemEpochs;
    // Fee tracking
    /// @dev Total accumulated fees (from deposits and withdrawals/redemptions)
    uint256 accumulatedFees;
  }

  function layout() internal pure returns (Layout storage $) {
    bytes32 slot = SLOT;
    assembly {
      $.slot := slot
    }
  }
}
