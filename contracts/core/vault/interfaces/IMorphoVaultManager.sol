// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @title IMorphoVaultManager Interface
/// @author BaseVol Team
/// @notice Interface for MorphoVaultManager contract that handles Morpho Vault interactions
interface IMorphoVaultManager {
  /// @notice Deposits assets to Morpho Vault
  /// @param amount The amount of assets to deposit
  function depositToMorpho(uint256 amount) external;

  /// @notice Withdraws assets from Morpho Vault
  /// @param amount The amount of assets to withdraw
  function withdrawFromMorpho(uint256 amount) external;

  /// @notice Redeems shares from Morpho Vault
  /// @param shares The amount of shares to redeem
  function redeemFromMorpho(uint256 shares) external;

  /// @notice Gets the Morpho Vault balance in assets
  /// @return The asset balance in the Morpho Vault
  function morphoAssetBalance() external view returns (uint256);

  /// @notice Gets the Morpho Vault balance in shares
  /// @return The share balance in the Morpho Vault
  function morphoShareBalance() external view returns (uint256);

  /// @notice Gets the total deposited amount
  /// @return The total deposited amount
  function totalDeposited() external view returns (uint256);

  /// @notice Gets the total withdrawn amount
  /// @return The total withdrawn amount
  function totalWithdrawn() external view returns (uint256);

  /// @notice Gets the total utilized amount (current asset value)
  /// @return The total utilized amount
  function totalUtilized() external view returns (uint256); // = morphoAssetBalance()

  /// @notice Gets the current yield/profit from Morpho
  /// @return The accumulated yield
  function currentYield() external view returns (uint256);
}
