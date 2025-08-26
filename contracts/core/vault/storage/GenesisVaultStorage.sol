// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library GenesisVaultStorage {
  // keccak256(abi.encode(uint256(keccak256("com.basevol.storage.genesisvault")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 internal constant SLOT =
    0x5ee42217d3eb996ad2b1dbf985c1bba88b7a17b6b441c8b6deb9a267d873da00;

  struct WithdrawRequest {
    /// @dev The requested assets to withdraw.
    uint256 requestedAssets;
    /// @dev The accumulated withdraw assets value that is used for claimability.
    uint256 accRequestedWithdrawAssets;
    /// @dev The block.timestamp when the request was created.
    uint256 requestTimestamp;
    /// @dev The owner who requested to withdraw.
    address owner;
    /// @dev The account who is receiving the executed withdrawal assets.
    address receiver;
    /// @dev Tells if a withdraw request is prioritized.
    bool isPrioritized;
    /// @dev True means claimed.
    bool isClaimed;
  }

  struct Layout {
    address strategy;
    uint256 entryCost;
    uint256 exitCost;
    // withdraw state
    uint256 assetsToClaim; // asset balance of vault that is ready to claim
    uint256 accRequestedWithdrawAssets; // total requested withdraw assets
    uint256 processedWithdrawAssets; // total processed assets
    mapping(address => uint256) nonces;
    mapping(bytes32 => WithdrawRequest) withdrawRequests;
    address admin;
    address[] prioritizedAccounts;
    uint256 prioritizedAccRequestedWithdrawAssets;
    uint256 prioritizedProcessedWithdrawAssets;
    bool shutdown;
    /* IMPROTANT: you can add new variables here */
  }

  function layout() internal pure returns (Layout storage $) {
    bytes32 slot = SLOT;
    assembly {
      $.slot := slot
    }
  }
}
