// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IGenesisStrategyErrors {
  // Authorization errors
  error CallerNotAuthorized(address authorized, address caller);
  error CallerNotOwnerOrVault();

  // Strategy operation errors
  error ZeroAmountUtilization();
  error InvalidStrategyStatus(uint8 currentStatus, uint8 targetStatus);

  // Leverage configuration errors
  error InvalidLeverageConfiguration();
  error TargetLeverageCannotBeZero();
  error MinLeverageMustBeLessThanTarget();
  error MaxLeverageMustBeGreaterThanTarget();
  error SafeMarginLeverageMustBeGreaterThanMax();

  // Strategy state errors
  error StrategyNotIdle();
  error StrategyAlreadyPaused();
  error StrategyNotPaused();
  error InsufficientClearingHouseBalance(uint256 available, uint256 required);
  error InsufficientUtilizedAssets(uint256 available, uint256 required);

  // Order management errors
  error InvalidOrderAmount();
  error InvalidEpoch();
  error OrderAlreadySubmitted();
  error OrderNotSubmitted();
}
