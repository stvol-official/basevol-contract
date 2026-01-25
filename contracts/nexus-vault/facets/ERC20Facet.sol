// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { LibNexusVaultStorage } from "../libraries/LibNexusVaultStorage.sol";
import "../errors/NexusVaultErrors.sol";

/**
 * @title ERC20Facet
 * @author BaseVol Team
 * @notice ERC20 token functionality for NexusVault shares
 * @dev Implements standard ERC20 interface for vault share tokens
 *
 * This facet handles:
 * - Share token transfers
 * - Allowance management
 * - Balance queries
 * - Token metadata
 */
contract ERC20Facet is IERC20, IERC20Metadata {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    // ERC20 events are inherited from IERC20

    /*//////////////////////////////////////////////////////////////
                            ERC20 METADATA
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get token name
     * @return Vault token name
     */
    function name() external view override returns (string memory) {
        return LibNexusVaultStorage.layout().name;
    }

    /**
     * @notice Get token symbol
     * @return Vault token symbol
     */
    function symbol() external view override returns (string memory) {
        return LibNexusVaultStorage.layout().symbol;
    }

    /**
     * @notice Get token decimals
     * @return Number of decimals (matches underlying asset)
     */
    function decimals() external view override returns (uint8) {
        return LibNexusVaultStorage.layout().decimals;
    }

    /*//////////////////////////////////////////////////////////////
                            ERC20 CORE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get total supply of vault shares
     * @return Total shares in circulation
     */
    function totalSupply() external view override returns (uint256) {
        return LibNexusVaultStorage.layout().totalSupply;
    }

    /**
     * @notice Get share balance of an account
     * @param account Address to query
     * @return Share balance
     */
    function balanceOf(
        address account
    ) external view override returns (uint256) {
        return LibNexusVaultStorage.layout().balances[account];
    }

    /**
     * @notice Transfer shares to another address
     * @param to Recipient address
     * @param amount Amount of shares to transfer
     * @return success True if transfer succeeded
     *
     * Requirements:
     * - to cannot be zero address
     * - caller must have sufficient balance
     */
    function transfer(
        address to,
        uint256 amount
    ) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /**
     * @notice Get allowance for spender
     * @param owner_ Token owner
     * @param spender Spender address
     * @return Allowance amount
     */
    function allowance(
        address owner_,
        address spender
    ) external view override returns (uint256) {
        return LibNexusVaultStorage.layout().allowances[owner_][spender];
    }

    /**
     * @notice Approve spender to transfer shares
     * @param spender Address to approve
     * @param amount Amount to approve
     * @return success True if approval succeeded
     *
     * Requirements:
     * - spender cannot be zero address
     */
    function approve(
        address spender,
        uint256 amount
    ) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice Transfer shares from one address to another
     * @param from Source address
     * @param to Destination address
     * @param amount Amount of shares to transfer
     * @return success True if transfer succeeded
     *
     * Requirements:
     * - from and to cannot be zero addresses
     * - from must have sufficient balance
     * - caller must have sufficient allowance
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                            ERC20 EXTENSIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Increase allowance for spender
     * @param spender Address to increase allowance for
     * @param addedValue Amount to add to allowance
     * @return success True if operation succeeded
     */
    function increaseAllowance(
        address spender,
        uint256 addedValue
    ) external returns (bool) {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();
        _approve(
            msg.sender,
            spender,
            s.allowances[msg.sender][spender] + addedValue
        );
        return true;
    }

    /**
     * @notice Decrease allowance for spender
     * @param spender Address to decrease allowance for
     * @param subtractedValue Amount to subtract from allowance
     * @return success True if operation succeeded
     *
     * Requirements:
     * - spender must have allowance >= subtractedValue
     */
    function decreaseAllowance(
        address spender,
        uint256 subtractedValue
    ) external returns (bool) {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();
        uint256 currentAllowance = s.allowances[msg.sender][spender];

        if (currentAllowance < subtractedValue) {
            revert InsufficientAllowance(subtractedValue, currentAllowance);
        }

        unchecked {
            _approve(msg.sender, spender, currentAllowance - subtractedValue);
        }
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal transfer implementation
     * @param from Source address
     * @param to Destination address
     * @param amount Amount to transfer
     */
    function _transfer(address from, address to, uint256 amount) internal {
        if (from == address(0)) revert Unauthorized();
        if (to == address(0)) revert InvalidReceiver();

        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        uint256 fromBalance = s.balances[from];
        if (fromBalance < amount) {
            revert InsufficientBalance(amount, fromBalance);
        }

        unchecked {
            s.balances[from] = fromBalance - amount;
            // Overflow not possible: sum of balances <= totalSupply
            s.balances[to] += amount;
        }

        emit Transfer(from, to, amount);
    }

    /**
     * @notice Internal approve implementation
     * @param owner_ Token owner
     * @param spender Spender address
     * @param amount Amount to approve
     */
    function _approve(
        address owner_,
        address spender,
        uint256 amount
    ) internal {
        if (owner_ == address(0)) revert Unauthorized();
        if (spender == address(0)) revert InvalidReceiver();

        LibNexusVaultStorage.layout().allowances[owner_][spender] = amount;

        emit Approval(owner_, spender, amount);
    }

    /**
     * @notice Spend allowance (internal)
     * @param owner_ Token owner
     * @param spender Spender address
     * @param amount Amount to spend
     */
    function _spendAllowance(
        address owner_,
        address spender,
        uint256 amount
    ) internal {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();
        uint256 currentAllowance = s.allowances[owner_][spender];

        // Unlimited allowance (max uint256) doesn't decrease
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) {
                revert InsufficientAllowance(amount, currentAllowance);
            }
            unchecked {
                s.allowances[owner_][spender] = currentAllowance - amount;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL MINT/BURN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Mint shares to an address (internal)
     * @dev Only called by core facet during deposits
     * @param to Recipient address
     * @param amount Amount of shares to mint
     */
    function _mint(address to, uint256 amount) internal {
        if (to == address(0)) revert InvalidReceiver();

        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        s.totalSupply += amount;
        unchecked {
            // Overflow not possible: balance + amount <= totalSupply
            s.balances[to] += amount;
        }

        emit Transfer(address(0), to, amount);
    }

    /**
     * @notice Burn shares from an address (internal)
     * @dev Only called by core facet during withdrawals
     * @param from Address to burn from
     * @param amount Amount of shares to burn
     */
    function _burn(address from, uint256 amount) internal {
        if (from == address(0)) revert Unauthorized();

        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        uint256 balance = s.balances[from];
        if (balance < amount) {
            revert InsufficientBalance(amount, balance);
        }

        unchecked {
            s.balances[from] = balance - amount;
            // Underflow not possible: amount <= balance <= totalSupply
            s.totalSupply -= amount;
        }

        emit Transfer(from, address(0), amount);
    }
}
