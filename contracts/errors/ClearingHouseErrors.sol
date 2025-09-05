// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
import { ICommonErrors } from "./CommonErrors.sol";

interface IClearingHouseErrors is ICommonErrors {
  error InvalidIdx();
  error RequestAlreadyProcessed();
  error InvalidTokenAddress();
  error ForceWithdrawalRequestNotFound();
  error ForceWithdrawalTooEarly();
  error ExistingForceWithdrawalRequest();
  error EpochHasNotStartedYet();
  error InvalidIndex();
  error InvalidRequestId();
  error InvalidBatchId();
  error BatchAlreadyProcessed();
  error ProductNotActive();
  error OperatorAlreadyExists();
  error BaseVolManagerAlreadyExists();
  error AmountExceedsLimit();
}
