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
   * @notice Returns the total assets under management including idle assets in strategy
   * @dev This includes strategy idle assets + BaseVol assets + Morpho assets (real-time)
   * @return Total assets managed by this strategy
   */
  function totalAssetsUnderManagement() external view returns (uint256);

  /**
   * @notice Returns the breakdown of assets under management by location
   * @dev Returns three separate values for different asset locations
   * @return strategyIdleAssets The amount of idle assets held in the strategy contract
   * @return baseVolAssets The amount of assets deployed in BaseVol
   * @return morphoAssets The amount of assets deployed in Morpho
   */
  function assetsUnderManagement() external view returns (uint256, uint256, uint256);
  /**
   * @notice Processes assets that are pending withdrawal
   * @dev This function handles the withdrawal queue and processes pending requests
   */
  function processAssetsToWithdraw() external;

  /**
   * @notice Provides liquidity for vault withdrawal requests by intelligently sourcing from available assets
   * @dev Only callable by vault. Attempts to fulfill request from: 1) idle assets, 2) BaseVol, 3) Morpho
   * @param amountNeeded The amount of liquidity needed by the vault
   */
  function provideLiquidityForWithdrawals(uint256 amountNeeded) external;

  /**
   * @notice Withdraws all BaseVol assets to idle for round settlement accounting
   * @dev Called by vault during round settlement to ensure clean accounting per round
   * @dev Only withdraws withdrawable assets (excludes escrowed funds)
   */
  function withdrawAllBaseVolForSettlement() external;

  /**
   * @notice Callback function called when a deposit operation completes
   * @param amount The amount that was deposited
   * @param success Whether the deposit operation was successful
   */
  function baseVolDepositCompletedCallback(uint256 amount, bool success) external;

  /**
   * @notice Callback function called when a BaseVol withdrawal operation completes
   * @param amount The amount that was withdrawn
   * @param success Whether the withdrawal operation was successful
   */
  function baseVolWithdrawCompletedCallback(uint256 amount, bool success) external;

  /**
   * @notice Callback function called when a Morpho deposit operation completes
   * @param amount The amount that was deposited to Morpho
   * @param success Whether the Morpho deposit operation was successful
   */
  function morphoDepositCompletedCallback(uint256 amount, bool success) external;

  /**
   * @notice Callback function called when a Morpho withdrawal operation completes
   * @param amount The amount that was withdrawn from Morpho
   * @param success Whether the Morpho withdrawal operation was successful
   */
  function morphoWithdrawCompletedCallback(uint256 amount, bool success) external;

  /**
   * @notice Callback function called when a Morpho redeem operation completes
   * @param shares The amount of shares that were redeemed from Morpho
   * @param assets The amount of assets received from Morpho
   * @param success Whether the Morpho redeem operation was successful
   */
  function morphoRedeemCompletedCallback(uint256 shares, uint256 assets, bool success) external;

  /**
   * @notice Returns the current balance of assets in the strategy
   * @return The current strategy balance
   */
  function strategyBalance() external view returns (uint256);

  /**
   * @notice Reset strategyBalance to match current real assets
   * @dev Emergency function to fix incorrect strategyBalance
   * @dev Only callable by owner when strategy is idle
   * @dev This will reset PnL tracking to zero
   */
  function resetStrategyBalance() external;
}
