// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title IGenesisVault
 * @notice Interface for GenesisVault deposit functions
 */
interface IGenesisVault {
  /**
   * @notice Deposit from ClearingHouse without entry fee
   * @dev Only callable by ClearingHouse contract
   * @param assets The amount of assets to deposit
   * @param user The address of the user
   * @return requestId The ID of the request (epoch number)
   */
  function depositFromClearingHouse(
    uint256 assets,
    address user
  ) external returns (uint256 requestId);
}
