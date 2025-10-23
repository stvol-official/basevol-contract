// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @title IBaseVolManager Interface
/// @author BaseVol Team
/// @notice Interface for BaseVolManager contract that handles ClearingHouse interactions
interface IBaseVolManager {
  /// @notice Deposits assets to ClearingHouse
  /// @param amount The amount of assets to deposit
  function depositToClearingHouse(uint256 amount) external;

  /// @notice Withdraws assets from ClearingHouse
  /// @param amount The amount of assets to withdraw
  function withdrawFromClearingHouse(uint256 amount) external;

  /// @notice Gets the ClearingHouse balance
  /// @return The balance of the ClearingHouse
  function withdrawableClearingHouseBalance() external view returns (uint256);

  /// @notice Gets the total ClearingHouse balance
  /// @return The total balance of the ClearingHouse
  function totalClearingHouseBalance() external view returns (uint256);

  /// @notice Gets the total deposited amount
  /// @return The total deposited amount
  function totalDeposited() external view returns (uint256);

  /// @notice Gets the total withdrawn amount
  /// @return The total withdrawn amount
  function totalWithdrawn() external view returns (uint256);

  /// @notice Gets the total utilized amount
  /// @return The total utilized amount
  function totalUtilized() external view returns (uint256);

  /// @notice Gets the configuration
  /// @return maxStrategyDeposit The maximum amount of assets that can be deposited to BaseVol Manager
  /// @return minStrategyDeposit The minimum amount of assets that can be deposited to BaseVol Manager
  /// @return maxTotalExposure The maximum amount of assets that can be used for total exposure
  function config()
    external
    view
    returns (uint256 maxStrategyDeposit, uint256 minStrategyDeposit, uint256 maxTotalExposure);
}
