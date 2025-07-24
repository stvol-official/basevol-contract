// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
import { ICommonErrors } from "./CommonErrors.sol";

interface IBaseVolErrors is ICommonErrors {
  error InvalidCommissionFee();
  error VaultCannotDeposit();
  error InvalidId();
  error InvalidTokenAddress();
  error InvalidInitDate();
  error InvalidRound();
  error InvalidRoundPrice();
  error EpochHasNotStartedYet();
  error InvalidEpoch();
  error InvalidIndex();
  error PriceLengthMismatch();
  error InsufficientEscrowBalance(address user, uint256 available, uint256 required);
  error InvalidPriceId();
  error PriceIdAlreadyExists();
  error InvalidSymbol();
  error ProductIdAlreadyExists();
  error AlreadySettled();
  error InvalidStrike();
  error InvalidProductId();
  error InsufficientVerificationFee(uint256 required, uint256 provided);
  error InvalidChannel();
}
