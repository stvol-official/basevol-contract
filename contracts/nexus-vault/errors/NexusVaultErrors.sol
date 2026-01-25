// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title NexusVaultErrors
 * @author BaseVol Team
 * @notice Custom errors for NexusVault Diamond
 * @dev Centralized error definitions for gas-efficient reverts
 */

/*//////////////////////////////////////////////////////////////
                        ACCESS CONTROL ERRORS
//////////////////////////////////////////////////////////////*/

/// @notice Caller is not the contract owner
error OnlyOwner();

/// @notice Caller is not the admin or owner
error OnlyAdmin();

/// @notice Caller is not an authorized keeper
error OnlyKeeper();

/// @notice Caller is not authorized for the operation
error Unauthorized();

/*//////////////////////////////////////////////////////////////
                        VAULT MANAGEMENT ERRORS
//////////////////////////////////////////////////////////////*/

/// @notice Attempting to add a vault that already exists
/// @param vault The vault address that already exists
error VaultAlreadyExists(address vault);

/// @notice Referenced vault does not exist in the registry
/// @param vault The vault address that was not found
error VaultNotFound(address vault);

/// @notice Operation requires an active vault but vault is inactive
/// @param vault The inactive vault address
error VaultNotActive(address vault);

/// @notice Cannot remove vault with remaining assets
/// @param vault The vault address with assets
/// @param assets The remaining asset amount
error VaultNotEmpty(address vault, uint256 assets);

/// @notice Invalid vault address (zero address)
error InvalidVaultAddress();

/// @notice Vault's underlying asset doesn't match NexusVault's asset
/// @param expected Expected asset address
/// @param actual Actual asset address from vault
error AssetMismatch(address expected, address actual);

/// @notice Target vault does not implement ERC4626 interface
/// @param vault The non-compliant vault address
error NotERC4626Compliant(address vault);

/*//////////////////////////////////////////////////////////////
                        WEIGHT ERRORS
//////////////////////////////////////////////////////////////*/

/// @notice Vault weights do not sum to 100% (1e18)
/// @param sum The actual sum of weights
error WeightSumInvalid(uint256 sum);

/// @notice Individual weight value is invalid (zero or exceeds 100%)
error InvalidWeight();

/*//////////////////////////////////////////////////////////////
                        FEE ERRORS
//////////////////////////////////////////////////////////////*/

/// @notice Fee exceeds maximum allowed value
/// @param feeType Type of fee (e.g., "management", "performance")
/// @param value The invalid fee value
/// @param maxValue Maximum allowed value
error ExceedsMaxFee(string feeType, uint256 value, uint256 maxValue);

/// @notice Fee recipient address is invalid
error InvalidFeeRecipient();

/*//////////////////////////////////////////////////////////////
                        OPERATION ERRORS
//////////////////////////////////////////////////////////////*/

/// @notice Deposit or withdrawal amount is zero
error ZeroAmount();

/// @notice Share amount is zero
error ZeroShares();

/// @notice Insufficient share balance for operation
/// @param requested Amount requested
/// @param available Amount available
error InsufficientBalance(uint256 requested, uint256 available);

/// @notice Insufficient allowance for transfer
/// @param requested Amount requested
/// @param allowed Amount allowed
error InsufficientAllowance(uint256 requested, uint256 allowed);

/// @notice Deposit would exceed vault or user cap
/// @param requested Amount requested
/// @param remaining Remaining capacity
error DepositCapExceeded(uint256 requested, uint256 remaining);

/// @notice Receiver address is invalid (zero address)
error InvalidReceiver();

/*//////////////////////////////////////////////////////////////
                        REBALANCING ERRORS
//////////////////////////////////////////////////////////////*/

/// @notice Rebalance attempted before cooldown period elapsed
/// @param nextAllowedTime Timestamp when rebalance is next allowed
error RebalanceCooldown(uint256 nextAllowedTime);

/// @notice Slippage during rebalance exceeded maximum
/// @param expected Expected amount
/// @param actual Actual amount received
error SlippageExceeded(uint256 expected, uint256 actual);

/// @notice No rebalancing is needed (allocations within threshold)
error NoRebalanceNeeded();

/// @notice Rebalance threshold is invalid
error InvalidThreshold();

/*//////////////////////////////////////////////////////////////
                        STATE ERRORS
//////////////////////////////////////////////////////////////*/

/// @notice Operation not allowed while vault is paused
error VaultPaused();

/// @notice Operation not allowed while vault is shutdown
error VaultShutdown();

/// @notice Pause operation called when already paused
error AlreadyPaused();

/// @notice Unpause operation called when not paused
error NotPaused();

/// @notice Shutdown operation called when already shutdown
error AlreadyShutdown();

/// @notice Vault has already been initialized
error AlreadyInitialized();

/*//////////////////////////////////////////////////////////////
                        KEEPER ERRORS
//////////////////////////////////////////////////////////////*/

/// @notice Keeper address already exists
/// @param keeper The duplicate keeper address
error KeeperAlreadyExists(address keeper);

/// @notice Keeper address not found
/// @param keeper The keeper address not found
error KeeperNotFound(address keeper);

/*//////////////////////////////////////////////////////////////
                        REENTRANCY ERRORS
//////////////////////////////////////////////////////////////*/

/// @notice Reentrancy detected in guarded function
error ReentrancyGuardReentrantCall();
