// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
pragma abicoder v2;

import { BaseVolStrike } from "./BaseVolStrike.sol";

contract BaseVolOneDay is BaseVolStrike {
  // keccak256(abi.encode(uint256(keccak256("com.basevol.storage.oneday")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 internal constant SLOT =
    0xe1b51085499c220f50e2d14094cc48a00772aff9f5738ba727305f034d042d00;

  function _getStorageSlot() internal pure override returns (bytes32) {
    return SLOT;
  }

  function _getIntervalSeconds() internal pure override returns (uint256) {
    return 86400; // 1 day
  }

  function _getStartTimestamp() internal pure override returns (uint256) {
    return 1751356800; // 2025-07-01 08:00:00
  }
}
