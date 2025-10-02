// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibGenesisVaultStorage } from "./LibGenesisVaultStorage.sol";

/**
 * @title LibERC20
 * @notice Internal ERC20 operations library for GenesisVault Diamond
 * @dev Provides reusable ERC20 logic (_mint, _burn, _transfer, etc) to avoid code duplication across facets
 */
library LibERC20 {
  // ============ Events ============
  event Transfer(address indexed from, address indexed to, uint256 value);
  event Approval(address indexed owner, address indexed spender, uint256 value);

  // ============ Internal Functions ============

  /**
   * @notice Internal transfer function
   * @dev Transfers shares from one address to another
   * @param from The sender address
   * @param to The recipient address
   * @param amount The amount of shares to transfer
   */
  function _transfer(address from, address to, uint256 amount) internal {
    require(from != address(0), "LibERC20: transfer from the zero address");
    require(to != address(0), "LibERC20: transfer to the zero address");

    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    uint256 fromBalance = s.balances[from];
    require(fromBalance >= amount, "LibERC20: transfer amount exceeds balance");
    unchecked {
      s.balances[from] = fromBalance - amount;
      s.balances[to] += amount;
    }

    emit Transfer(from, to, amount);
  }

  /**
   * @notice Internal mint function
   * @dev Creates new shares and assigns them to an account
   * @param account The account to mint shares to
   * @param amount The amount of shares to mint
   */
  function _mint(address account, uint256 amount) internal {
    require(account != address(0), "LibERC20: mint to the zero address");

    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    s.totalSupply += amount;
    unchecked {
      s.balances[account] += amount;
    }

    emit Transfer(address(0), account, amount);
  }

  /**
   * @notice Internal burn function
   * @dev Destroys shares from an account
   * @param account The account to burn shares from
   * @param amount The amount of shares to burn
   */
  function _burn(address account, uint256 amount) internal {
    require(account != address(0), "LibERC20: burn from the zero address");

    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    uint256 accountBalance = s.balances[account];
    require(accountBalance >= amount, "LibERC20: burn amount exceeds balance");
    unchecked {
      s.balances[account] = accountBalance - amount;
      s.totalSupply -= amount;
    }

    emit Transfer(account, address(0), amount);
  }

  /**
   * @notice Internal approve function
   * @dev Sets the allowance of a spender over the owner's shares
   * @param owner The owner of the shares
   * @param spender The address allowed to spend the shares
   * @param amount The amount of shares to approve
   */
  function _approve(address owner, address spender, uint256 amount) internal {
    require(owner != address(0), "LibERC20: approve from the zero address");
    require(spender != address(0), "LibERC20: approve to the zero address");

    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    s.allowances[owner][spender] = amount;

    emit Approval(owner, spender, amount);
  }

  /**
   * @notice Internal spend allowance function
   * @dev Updates the allowance after spending shares
   * @param owner The owner of the shares
   * @param spender The address spending the shares
   * @param amount The amount of shares being spent
   */
  function _spendAllowance(address owner, address spender, uint256 amount) internal {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    uint256 currentAllowance = s.allowances[owner][spender];

    if (currentAllowance != type(uint256).max) {
      require(currentAllowance >= amount, "LibERC20: insufficient allowance");
      unchecked {
        _approve(owner, spender, currentAllowance - amount);
      }
    }
  }
}
