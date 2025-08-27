// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IGenesisVault
 * @notice Interface for GenesisVault functions used by GenesisStrategy
 */
interface IGenesisVault {
  /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Returns the amount of base assets that can be freely withdrawn or utilized from this vault
  function idleAssets() external view returns (uint256);

  /// @notice Returns the total assets
  function totalAssets() external view returns (uint256);

  /// @notice Returns the total supply
  function totalSupply() external view returns (uint256);

  /// @notice Returns the address of the base asset
  function asset() external view returns (address);

  /// @notice Returns whether the vault is paused
  function paused() external view returns (bool);

  /// @notice Returns whether this vault has been shut down
  function isShutdown() external view returns (bool);

  /// @notice Returns the total pending withdraw amount
  function totalPendingWithdraw() external view returns (uint256);

  /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Pauses the vault
  function pause(bool stopStrategy) external;

  /// @notice Unpauses the vault
  function unpause() external;

  /// @notice Shuts down the vault
  function shutdown() external;

  /// @notice Sets the strategy
  function setStrategy(address _strategy) external;

  /*//////////////////////////////////////////////////////////////
                            STRATEGY INTERACTION
  //////////////////////////////////////////////////////////////*/

  /// @notice Harvests performance fees (only callable from strategy)
  function harvestPerformanceFee() external;

  /// @notice Reserves execution costs (only callable from strategy)
  function reserveExecutionCost(uint256 amount) external;
}
