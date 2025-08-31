// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
pragma abicoder v2;

import { BaseVolStrike } from "./BaseVolStrike.sol";

contract BaseVolOneHour is BaseVolStrike {
  // keccak256(abi.encode(uint256(keccak256("com.basevol.storage.onehour.secure")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 internal constant SLOT =
    0x627bc893d5f4048695eb6f1d0f7e17f469d944fd83ca2c18162d4bfe5e67b400;

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
