// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @title IBaseVolManager Interface
/// @author BaseVol Team
/// @notice Interface for BaseVolManager contract that handles ClearingHouse interactions
interface IBaseVolManager {
  /// @notice Deposits assets to ClearingHouse
  /// @param amount The amount of assets to deposit
  function depositToClearingHouse(uint256 amount, address strategy) external;

  /// @notice Withdraws assets from ClearingHouse
  /// @param amount The amount of assets to withdraw
  function withdrawFromClearingHouse(uint256 amount, address strategy) external;

  /// @notice Gets the ClearingHouse balance
  /// @return The balance of the ClearingHouse
  function clearingHouseBalance() external view returns (uint256);

  /// @notice Gets the total deposited amount
  /// @return The total deposited amount
  function totalDeposited() external view returns (uint256);

  /// @notice Gets the total withdrawn amount
  /// @return The total withdrawn amount
  function totalWithdrawn() external view returns (uint256);

  /// @notice Gets the total utilized amount
  /// @return The total utilized amount
  function totalUtilized() external view returns (uint256);
}
