// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library GenesisVaultStorage {
  // keccak256(abi.encode(uint256(keccak256("com.basevol.storage.genesisvault")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 internal constant SLOT =
    0x5ee42217d3eb996ad2b1dbf985c1bba88b7a17b6b441c8b6deb9a267d873da00;

  struct DepositRequest {
    /// @dev The amount of assets to deposit.
    uint256 assets;
    /// @dev The address that will control the request.
    address controller;
    /// @dev The address that owns the deposited assets.
    address owner;
    /// @dev The block.timestamp when the request was created.
    uint256 timestamp;
    /// @dev True means claimed.
    bool isClaimed;
  }

  struct RedeemRequest {
    /// @dev The amount of shares to redeem.
    uint256 shares;
    /// @dev The calculated asset amount.
    uint256 assets;
    /// @dev The address that will control the request.
    address controller;
    /// @dev The address that owns the shares.
    address owner;
    /// @dev The block.timestamp when the request was created.
    uint256 timestamp;
    /// @dev Tells if a redeem request is prioritized.
    bool isPrioritized;
    /// @dev True means the request has been processed.
    bool isProcessed;
    // isClaimed removed for efficiency - ERC7540 uses pool-based tracking
  }

  struct Layout {
    address strategy;
    uint256 entryCost;
    uint256 exitCost;
    address admin;
    address[] prioritizedAccounts;
    bool shutdown;
    // ERC7540 deposit state
    uint256 nextRequestId;
    mapping(address => uint256) pendingDepositAssets;
    mapping(uint256 => DepositRequest) depositRequests;
    // ERC7540 operator system
    mapping(address => mapping(address => bool)) operators;
    // ERC7540 deposit accumulation state
    uint256 accRequestedDepositAssets;
    uint256 processedDepositAssets;
    uint256 claimedDepositAssets;
    // ERC7540 redeem state with priority support
    mapping(uint256 => RedeemRequest) redeemRequests;
    mapping(address => uint256) pendingRedeemShares;
    mapping(address => uint256) pendingRedeemAssets;
    // ERC7540 redeem accumulation state (priority-aware)
    uint256 prioritizedAccRequestedRedeemAssets;
    uint256 prioritizedProcessedRedeemAssets;
    uint256 prioritizedClaimedRedeemAssets;
    uint256 accRequestedRedeemAssets;
    uint256 processedRedeemAssets;
    uint256 claimedRedeemAssets;

    /* IMPROTANT: you can add new variables here */
  }

  function layout() internal pure returns (Layout storage $) {
    bytes32 slot = SLOT;
    assembly {
      $.slot := slot
    }
  }
}
