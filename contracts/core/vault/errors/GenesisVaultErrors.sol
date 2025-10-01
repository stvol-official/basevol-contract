// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @title IGenesisVaultErrors
/// @notice Custom errors for GenesisVault contracts
interface IGenesisVaultErrors {
  /// @notice Only admin can call this function
  error OnlyAdmin();

  /// @notice Invalid strategy configuration
  error InvalidStrategy();

  /// @notice Account is already prioritized
  error AccountAlreadyPrioritized();

  /// @notice Account is not prioritized
  error AccountNotPrioritized();

  /// @notice Caller is not the strategy
  error CallerNotStrategy();

  /// @notice Exceeded maximum request withdraw amount
  error ExceededMaxRequestWithdraw(address owner, uint256 assets, uint256 maxRequestAssets);

  /// @notice Exceeded maximum request redeem amount
  error ExceededMaxRequestRedeem(address owner, uint256 shares, uint256 maxRequestShares);

  /// @notice Request has already been claimed
  error RequestAlreadyClaimed();

  /// @notice Request has not been executed yet
  error RequestNotExecuted();

  /// @notice Zero shares not allowed
  error ZeroShares();

  /// @notice Address is not whitelisted
  error NotWhitelisted(address to);

  /// @notice Management fee transfer not allowed
  error ManagementFeeTransfer(address feeRecipient);

  /// @notice BaseVol contract not set
  error BaseVolContractNotSet();

  /// @notice Round already settled
  error RoundAlreadySettled(uint256 epoch);
}
