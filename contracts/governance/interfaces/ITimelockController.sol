// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title ITimelockController
 * @notice Interface for OpenZeppelin TimelockController
 * @dev Used for timelock protection on critical admin operations
 */
interface ITimelockController {
  /**
   * @dev Emitted when a call is scheduled as part of operation `id`.
   */
  event CallScheduled(
    bytes32 indexed id,
    uint256 indexed index,
    address target,
    uint256 value,
    bytes data,
    bytes32 predecessor,
    uint256 delay
  );

  /**
   * @dev Emitted when a call is performed as part of operation `id`.
   */
  event CallExecuted(
    bytes32 indexed id,
    uint256 indexed index,
    address target,
    uint256 value,
    bytes data
  );

  /**
   * @dev Emitted when operation `id` is cancelled.
   */
  event Cancelled(bytes32 indexed id);

  /**
   * @dev Returns the minimum delay for operations.
   */
  function getMinDelay() external view returns (uint256);

  /**
   * @dev Returns whether an id correspond to a registered operation. This
   * includes both Pending, Ready and Done operations.
   */
  function isOperation(bytes32 id) external view returns (bool);

  /**
   * @dev Returns whether an operation is pending or not.
   */
  function isOperationPending(bytes32 id) external view returns (bool);

  /**
   * @dev Returns whether an operation is ready or not.
   */
  function isOperationReady(bytes32 id) external view returns (bool);

  /**
   * @dev Returns whether an operation is done or not.
   */
  function isOperationDone(bytes32 id) external view returns (bool);

  /**
   * @dev Returns the timestamp at which an operation becomes ready (0 for
   * unset operations, 1 for done operations).
   */
  function getTimestamp(bytes32 id) external view returns (uint256);

  /**
   * @dev Schedule an operation containing a single transaction.
   */
  function schedule(
    address target,
    uint256 value,
    bytes calldata data,
    bytes32 predecessor,
    bytes32 salt,
    uint256 delay
  ) external;

  /**
   * @dev Execute an (ready) operation containing a single transaction.
   */
  function execute(
    address target,
    uint256 value,
    bytes calldata data,
    bytes32 predecessor,
    bytes32 salt
  ) external payable;

  /**
   * @dev Cancel an operation.
   */
  function cancel(bytes32 id) external;

  /**
   * @dev Returns the identifier of an operation containing a single transaction.
   */
  function hashOperation(
    address target,
    uint256 value,
    bytes calldata data,
    bytes32 predecessor,
    bytes32 salt
  ) external pure returns (bytes32);

  /**
   * @dev Returns the proposer role identifier.
   */
  function PROPOSER_ROLE() external view returns (bytes32);

  /**
   * @dev Returns the executor role identifier.
   */
  function EXECUTOR_ROLE() external view returns (bytes32);

  /**
   * @dev Returns the canceller role identifier.
   */
  function CANCELLER_ROLE() external view returns (bytes32);

  /**
   * @dev Returns the timelock admin role identifier.
   */
  function TIMELOCK_ADMIN_ROLE() external view returns (bytes32);
}
