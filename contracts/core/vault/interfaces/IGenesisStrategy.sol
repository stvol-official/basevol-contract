// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title IGenesisStrategy
 * @notice Interface for the Genesis Strategy contract that manages vault operations
 * @dev This interface defines the core functions for strategy management and asset operations
 */
interface IGenesisStrategy {
  /**
   * @notice Stops the strategy and prevents further operations
   * @dev This function should be called to halt all strategy activities
   */
  function stop() external;

  /**
   * @notice Returns the address of the underlying asset managed by this strategy
   * @return The address of the asset contract
   */
  function asset() external view returns (address);

  /**
   * @notice Returns the address of the vault that owns this strategy
   * @return The address of the vault contract
   */
  function vault() external view returns (address);

  /**
   * @notice Reserves execution cost for strategy operations
   * @param cost The amount of cost to reserve
   */
  function reserveExecutionCost(uint256 cost) external;

  /**
   * @notice Pauses the strategy, temporarily stopping operations
   * @dev Only callable by authorized accounts
   */
  function pause() external;

  /**
   * @notice Unpauses the strategy, resuming normal operations
   * @dev Only callable by authorized accounts
   */
  function unpause() external;

  /**
   * @notice Returns the total amount of assets currently utilized by the strategy
   * @return The amount of utilized assets
   */
  function utilizedAssets() external view returns (uint256);

  /**
   * @notice Processes assets that are pending withdrawal
   * @dev This function handles the withdrawal queue and processes pending requests
   */
  function processAssetsToWithdraw() external;

  /**
   * @notice Callback function called when a deposit operation completes
   * @param amount The amount that was deposited
   * @param success Whether the deposit operation was successful
   */
  function depositCompletedCallback(uint256 amount, bool success) external;

  /**
   * @notice Callback function called when a withdrawal operation completes
   * @param amount The amount that was withdrawn
   * @param success Whether the withdrawal operation was successful
   */
  function withdrawCompletedCallback(uint256 amount, bool success) external;

  /**
   * @notice Returns the current balance of assets in the strategy
   * @return The current strategy balance
   */
  function strategyBalance() external view returns (uint256);
}
