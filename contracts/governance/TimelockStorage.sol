// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title TimelockStorage
 * @notice Storage for timelock addresses in contracts
 */
library TimelockStorage {
  bytes32 constant TIMELOCK_STORAGE_POSITION = keccak256("basevol.storage.timelock");

  struct Layout {
    address criticalTimelock; // For fund-impacting operations (48h delay)
    address standardTimelock; // For UX-impacting operations (12h delay)
    bool timelockEnabled; // Global timelock toggle
  }

  function layout() internal pure returns (Layout storage l) {
    bytes32 position = TIMELOCK_STORAGE_POSITION;
    assembly {
      l.slot := position
    }
  }

  /**
   * @notice Get the critical timelock address
   */
  function getCriticalTimelock() internal view returns (address) {
    return layout().criticalTimelock;
  }

  /**
   * @notice Get the standard timelock address
   */
  function getStandardTimelock() internal view returns (address) {
    return layout().standardTimelock;
  }

  /**
   * @notice Check if timelock is enabled
   */
  function isTimelockEnabled() internal view returns (bool) {
    return layout().timelockEnabled;
  }

  /**
   * @notice Set the critical timelock address
   */
  function setCriticalTimelock(address _timelock) internal {
    layout().criticalTimelock = _timelock;
  }

  /**
   * @notice Set the standard timelock address
   */
  function setStandardTimelock(address _timelock) internal {
    layout().standardTimelock = _timelock;
  }

  /**
   * @notice Enable or disable timelock
   */
  function setTimelockEnabled(bool _enabled) internal {
    layout().timelockEnabled = _enabled;
  }
}
