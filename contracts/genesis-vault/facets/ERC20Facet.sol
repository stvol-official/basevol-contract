// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibGenesisVaultStorage } from "../libraries/LibGenesisVaultStorage.sol";
import { LibERC20 } from "../libraries/LibERC20.sol";

/**
 * @title ERC20Facet
 * @notice ERC20 functionality for GenesisVault Diamond
 * @dev Implements standard ERC20 transfer, approve, allowance functions
 */
contract ERC20Facet {
  // ============ ERC20 Functions ============

  /**
   * @notice Transfer shares
   * @dev SECURITY: Blocked when vault is paused or shutdown
   * @param to The recipient address
   * @param amount The amount of shares to transfer
   * @return success True if transfer succeeded
   */
  function transfer(address to, uint256 amount) external returns (bool) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    
    // SECURITY FIX: Add pause/shutdown check to prevent emergency control bypass
    require(!s.paused && !s.shutdown, "ERC20Facet: Vault not active");
    
    address owner = msg.sender;
    LibERC20._transfer(owner, to, amount);
    return true;
  }

  /**
   * @notice Approve spender to transfer shares
   * @param spender The spender address
   * @param amount The amount to approve
   * @return success True if approval succeeded
   */
  function approve(address spender, uint256 amount) external returns (bool) {
    address owner = msg.sender;
    LibERC20._approve(owner, spender, amount);
    return true;
  }

  /**
   * @notice Transfer shares from another account
   * @dev SECURITY: Blocked when vault is paused or shutdown
   * @param from The sender address
   * @param to The recipient address
   * @param amount The amount of shares to transfer
   * @return success True if transfer succeeded
   */
  function transferFrom(address from, address to, uint256 amount) external returns (bool) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    
    // SECURITY FIX: Add pause/shutdown check to prevent emergency control bypass
    require(!s.paused && !s.shutdown, "ERC20Facet: Vault not active");
    
    address spender = msg.sender;
    LibERC20._spendAllowance(from, spender, amount);
    LibERC20._transfer(from, to, amount);
    return true;
  }

  /**
   * @notice Increase allowance
   * @param spender The spender address
   * @param addedValue The amount to increase
   * @return success True if succeeded
   */
  function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    address owner = msg.sender;
    LibERC20._approve(owner, spender, s.allowances[owner][spender] + addedValue);
    return true;
  }

  /**
   * @notice Decrease allowance
   * @param spender The spender address
   * @param subtractedValue The amount to decrease
   * @return success True if succeeded
   */
  function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    address owner = msg.sender;
    uint256 currentAllowance = s.allowances[owner][spender];
    require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
    unchecked {
      LibERC20._approve(owner, spender, currentAllowance - subtractedValue);
    }
    return true;
  }

  /// views

  /**
   * @notice Get vault name
   */
  function name() external view returns (string memory) {
    return LibGenesisVaultStorage.layout().name;
  }

  /**
   * @notice Get vault symbol
   */
  function symbol() external view returns (string memory) {
    return LibGenesisVaultStorage.layout().symbol;
  }

  /**
   * @notice Get total supply of shares
   */
  function totalSupply() external view returns (uint256) {
    return LibGenesisVaultStorage.layout().totalSupply;
  }

  /**
   * @notice Get vault share decimals
   * @dev Returns cached decimals from storage
   */
  function decimals() public view returns (uint8) {
    return LibGenesisVaultStorage.layout().decimals;
  }

  /**
   * @notice Get balance of shares for an account
   */
  function balanceOf(address account) external view returns (uint256) {
    return LibGenesisVaultStorage.layout().balances[account];
  }

  /**
   * @notice Get allowance
   */
  function allowance(address owner, address spender) external view returns (uint256) {
    return LibGenesisVaultStorage.layout().allowances[owner][spender];
  }
}
