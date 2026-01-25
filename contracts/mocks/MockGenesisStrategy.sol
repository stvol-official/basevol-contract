// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IGenesisStrategy } from "../core/vault/interfaces/IGenesisStrategy.sol";

/// @title MockGenesisStrategy
/// @notice Mock Genesis Strategy for testing MorphoVaultManager
contract MockGenesisStrategy is IGenesisStrategy {
  address public immutable _asset;
  address public _vault;

  // Callback tracking for tests
  uint256 public lastDepositAmount;
  bool public lastDepositSuccess;
  uint256 public lastWithdrawAmount;
  bool public lastWithdrawSuccess;
  uint256 public lastRedeemShares;
  uint256 public lastRedeemAssets;
  bool public lastRedeemSuccess;

  constructor(address asset_) {
    _asset = asset_;
  }

  function stop() external override {
    // No-op for mock
  }

  function asset() external view override returns (address) {
    return _asset;
  }

  function vault() external view override returns (address) {
    return _vault;
  }

  function setVault(address vault_) external {
    _vault = vault_;
  }

  function reserveExecutionCost(uint256) external override {
    // No-op for mock
  }

  function pause() external override {
    // No-op for mock
  }

  function unpause() external override {
    // No-op for mock
  }

  function totalAssetsUnderManagement() external pure override returns (uint256) {
    return 0;
  }

  function assetsUnderManagement() external pure override returns (uint256, uint256, uint256) {
    return (0, 0, 0);
  }

  function processAssetsToWithdraw() external override {
    // No-op for mock
  }

  function provideLiquidityForWithdrawals(uint256) external override {
    // No-op for mock
  }

  function withdrawAllStrategyAssetsForSettlement() external override {
    // No-op for mock
  }

  function baseVolDepositCompletedCallback(uint256, bool) external override {
    // No-op for mock
  }

  function baseVolWithdrawCompletedCallback(uint256, bool) external override {
    // No-op for mock
  }

  function morphoDepositCompletedCallback(uint256 amount, bool success) external override {
    lastDepositAmount = amount;
    lastDepositSuccess = success;
  }

  function morphoWithdrawCompletedCallback(uint256 amount, bool success) external override {
    lastWithdrawAmount = amount;
    lastWithdrawSuccess = success;
  }

  function morphoRedeemCompletedCallback(
    uint256 shares,
    uint256 assets,
    bool success
  ) external override {
    lastRedeemShares = shares;
    lastRedeemAssets = assets;
    lastRedeemSuccess = success;
  }

  function strategyBalance() external pure override returns (uint256) {
    return 0;
  }

  function resetStrategyBalance() external override {
    // No-op for mock
  }
}
