// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
pragma abicoder v2;

import { BaseVolStrike } from "./BaseVolStrike.sol";

contract BaseVolOneHour is BaseVolStrike {
  // keccak256(abi.encode(uint256(keccak256("com.basevol.storage.onehour")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 internal constant SLOT =
    0xc1bd0a8ce0f829aa5016dd12be089da9ed424e930a2ec7765d867ab544f65100;

  function _getStorageSlot() internal pure override returns (bytes32) {
    return SLOT;
  }

  function _getIntervalSeconds() internal pure override returns (uint256) {
    return 3600; // 1 hour
  }

  function _getStartTimestamp() internal pure override returns (uint256) {
    return 1750636800; // 2025-06-23 00:00:00
  }
}
