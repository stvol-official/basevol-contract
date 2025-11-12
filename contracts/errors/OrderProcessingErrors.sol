// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title OrderProcessingErrors
 * @notice Custom errors for OrderProcessingFacet
 */

/// @notice Thrown when an empty transactions array is provided
error EmptyTransactionsArray();

/// @notice Thrown when order IDs are not sequential
/// @param lastId The last filled order ID in storage
/// @param firstId The first order ID in the submitted batch
error InvalidOrderSequence(uint256 lastId, uint256 firstId);
