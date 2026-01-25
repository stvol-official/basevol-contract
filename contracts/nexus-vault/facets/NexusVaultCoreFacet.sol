// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { LibNexusVaultStorage } from "../libraries/LibNexusVaultStorage.sol";
import { LibNexusVaultAuth } from "../libraries/LibNexusVaultAuth.sol";
import { LibNexusVault } from "../libraries/LibNexusVault.sol";
import "../errors/NexusVaultErrors.sol";

/**
 * @title NexusVaultCoreFacet
 * @author BaseVol Team
 * @notice Core ERC4626 vault operations for NexusVault
 * @dev Implements deposit, withdraw, mint, and redeem with multi-vault distribution
 *
 * Key features:
 * - Synchronous deposits and withdrawals (unlike ERC7540)
 * - Automatic distribution across underlying vaults based on target weights
 * - Proportional withdrawal from vaults based on current holdings
 * - Reentrancy protection on all state-changing functions
 * - Fee application (deposit/withdraw fees)
 */
contract NexusVaultCoreFacet {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant FLOAT_PRECISION = 1e18;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted on successful deposit
    event Deposit(
        address indexed sender,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    /// @notice Emitted on successful withdrawal
    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Prevents reentrancy attacks
    modifier nonReentrant() {
        LibNexusVaultAuth.nonReentrantBefore();
        _;
        LibNexusVaultAuth.nonReentrantAfter();
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSIT OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit assets and receive vault shares
     * @dev Distributes assets across underlying vaults according to target weights
     *
     * Flow:
     * 1. Validate operational state and amounts
     * 2. Calculate shares to mint (accounting for deposit fee)
     * 3. Transfer assets from sender
     * 4. Apply deposit fee if configured
     * 5. Distribute remaining assets to underlying vaults
     * 6. Mint shares to receiver
     *
     * @param assets Amount of assets to deposit
     * @param receiver Address to receive minted shares
     * @return shares Amount of shares minted
     *
     * Requirements:
     * - Vault must not be paused or shutdown
     * - Amount must be > 0
     * - At least one active vault must exist
     */
    function deposit(
        uint256 assets,
        address receiver
    ) external nonReentrant returns (uint256 shares) {
        // Validate state
        LibNexusVaultAuth.enforceOperational();

        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidReceiver();

        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        // Check deposit caps
        uint256 maxAssets = LibNexusVault.maxDeposit(receiver);
        if (assets > maxAssets) {
            revert DepositCapExceeded(assets, maxAssets);
        }

        // Calculate shares before any state changes
        shares = LibNexusVault.previewDeposit(assets);
        if (shares == 0) revert ZeroShares();

        // Transfer assets from sender
        IERC20(address(s.asset)).safeTransferFrom(msg.sender, address(this), assets);

        // Apply deposit fee if configured
        uint256 netAssets = assets;
        if (s.feeConfig.depositFee > 0) {
            uint256 fee = assets.mulDiv(
                s.feeConfig.depositFee,
                FLOAT_PRECISION,
                Math.Rounding.Ceil
            );
            if (fee > 0 && s.feeConfig.feeRecipient != address(0)) {
                IERC20(address(s.asset)).safeTransfer(s.feeConfig.feeRecipient, fee);
                netAssets = assets - fee;
            }
        }

        // Distribute to underlying vaults
        _distributeToVaults(netAssets);

        // Mint shares to receiver
        _mint(receiver, shares);

        // Update tracking
        s.totalDeposited += assets;

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @notice Mint exact shares by depositing assets
     * @dev Similar to deposit but specifies exact shares output
     *
     * @param shares Exact amount of shares to mint
     * @param receiver Address to receive minted shares
     * @return assets Amount of assets deposited
     *
     * Requirements:
     * - Vault must not be paused or shutdown
     * - Shares must be > 0
     */
    function mint(
        uint256 shares,
        address receiver
    ) external nonReentrant returns (uint256 assets) {
        // Validate state
        LibNexusVaultAuth.enforceOperational();

        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert InvalidReceiver();

        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        // Calculate assets needed
        assets = LibNexusVault.previewMint(shares);
        if (assets == 0) revert ZeroAmount();

        // Check deposit caps
        uint256 maxAssets = LibNexusVault.maxDeposit(receiver);
        if (assets > maxAssets) {
            revert DepositCapExceeded(assets, maxAssets);
        }

        // Transfer assets from sender
        IERC20(address(s.asset)).safeTransferFrom(msg.sender, address(this), assets);

        // Apply deposit fee if configured
        uint256 netAssets = assets;
        if (s.feeConfig.depositFee > 0) {
            uint256 fee = assets.mulDiv(
                s.feeConfig.depositFee,
                FLOAT_PRECISION,
                Math.Rounding.Ceil
            );
            if (fee > 0 && s.feeConfig.feeRecipient != address(0)) {
                IERC20(address(s.asset)).safeTransfer(s.feeConfig.feeRecipient, fee);
                netAssets = assets - fee;
            }
        }

        // Distribute to underlying vaults
        _distributeToVaults(netAssets);

        // Mint shares to receiver
        _mint(receiver, shares);

        // Update tracking
        s.totalDeposited += assets;

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /*//////////////////////////////////////////////////////////////
                            WITHDRAW OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Withdraw exact assets by burning shares
     * @dev Withdraws proportionally from underlying vaults
     *
     * Flow:
     * 1. Validate state and amounts
     * 2. Calculate shares to burn (accounting for withdraw fee)
     * 3. Verify owner balance and allowance
     * 4. Burn shares from owner
     * 5. Withdraw from underlying vaults
     * 6. Apply withdraw fee if configured
     * 7. Transfer net assets to receiver
     *
     * @param assets Exact amount of assets to withdraw
     * @param receiver Address to receive assets
     * @param owner Address that owns the shares
     * @return shares Amount of shares burned
     *
     * Requirements:
     * - Vault must not be paused (shutdown allows withdrawals)
     * - Amount must be > 0
     * - Owner must have sufficient shares
     * - Caller must be owner or have sufficient allowance
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external nonReentrant returns (uint256 shares) {
        // Validate state (withdrawals allowed when shutdown, not when paused)
        LibNexusVaultAuth.enforceWithdrawable();

        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidReceiver();

        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        // Calculate shares to burn
        shares = LibNexusVault.previewWithdraw(assets);
        if (shares == 0) revert ZeroShares();

        // Check balance
        uint256 ownerBalance = s.balances[owner];
        if (ownerBalance < shares) {
            revert InsufficientBalance(shares, ownerBalance);
        }

        // Check allowance if caller is not owner
        if (msg.sender != owner) {
            uint256 allowed = s.allowances[owner][msg.sender];
            if (allowed < shares) {
                revert InsufficientAllowance(shares, allowed);
            }
            if (allowed != type(uint256).max) {
                s.allowances[owner][msg.sender] = allowed - shares;
            }
        }

        // Burn shares first (checks-effects-interactions)
        _burn(owner, shares);

        // Calculate gross assets (before fee)
        uint256 grossAssets = assets;
        if (s.feeConfig.withdrawFee > 0) {
            // grossAssets = netAssets / (1 - fee)
            grossAssets = assets.mulDiv(
                FLOAT_PRECISION,
                FLOAT_PRECISION - s.feeConfig.withdrawFee,
                Math.Rounding.Ceil
            );
        }

        // Withdraw from underlying vaults
        _withdrawFromVaults(grossAssets);

        // Apply withdraw fee if configured
        if (s.feeConfig.withdrawFee > 0) {
            uint256 fee = grossAssets - assets;
            if (fee > 0 && s.feeConfig.feeRecipient != address(0)) {
                IERC20(address(s.asset)).safeTransfer(s.feeConfig.feeRecipient, fee);
            }
        }

        // Transfer net assets to receiver
        IERC20(address(s.asset)).safeTransfer(receiver, assets);

        // Update tracking
        s.totalWithdrawn += grossAssets;

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /**
     * @notice Redeem exact shares for assets
     * @dev Similar to withdraw but specifies exact shares to burn
     *
     * @param shares Exact amount of shares to redeem
     * @param receiver Address to receive assets
     * @param owner Address that owns the shares
     * @return assets Amount of assets received
     *
     * Requirements:
     * - Vault must not be paused
     * - Shares must be > 0
     * - Owner must have sufficient shares
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external nonReentrant returns (uint256 assets) {
        // Validate state
        LibNexusVaultAuth.enforceWithdrawable();

        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert InvalidReceiver();

        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        // Check balance
        uint256 ownerBalance = s.balances[owner];
        if (ownerBalance < shares) {
            revert InsufficientBalance(shares, ownerBalance);
        }

        // Check allowance if caller is not owner
        if (msg.sender != owner) {
            uint256 allowed = s.allowances[owner][msg.sender];
            if (allowed < shares) {
                revert InsufficientAllowance(shares, allowed);
            }
            if (allowed != type(uint256).max) {
                s.allowances[owner][msg.sender] = allowed - shares;
            }
        }

        // Calculate assets to receive (after fee)
        assets = LibNexusVault.previewRedeem(shares);
        if (assets == 0) revert ZeroAmount();

        // Burn shares first
        _burn(owner, shares);

        // Calculate gross assets (before fee)
        uint256 grossAssets = LibNexusVault.convertToAssets(shares);

        // Withdraw from underlying vaults
        _withdrawFromVaults(grossAssets);

        // Apply withdraw fee if configured
        if (s.feeConfig.withdrawFee > 0) {
            uint256 fee = grossAssets - assets;
            if (fee > 0 && s.feeConfig.feeRecipient != address(0)) {
                IERC20(address(s.asset)).safeTransfer(s.feeConfig.feeRecipient, fee);
            }
        }

        // Transfer net assets to receiver
        IERC20(address(s.asset)).safeTransfer(receiver, assets);

        // Update tracking
        s.totalWithdrawn += grossAssets;

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Distribute assets to underlying vaults based on target weights
     * @dev Uses LibNexusVault.calculateDepositAllocation for proportional distribution
     * @param amount Total amount to distribute
     */
    function _distributeToVaults(uint256 amount) internal {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        (address[] memory vaults, uint256[] memory amounts) =
            LibNexusVault.calculateDepositAllocation(amount);

        IERC20 asset = s.asset;
        uint256 length = vaults.length;

        for (uint256 i = 0; i < length; ) {
            if (amounts[i] > 0) {
                // Approve and deposit to underlying vault
                asset.forceApprove(vaults[i], amounts[i]);
                IERC4626(vaults[i]).deposit(amounts[i], address(this));
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Withdraw assets from underlying vaults proportionally
     * @dev Uses idle assets first, then withdraws from vaults
     * @param amount Total amount to withdraw
     */
    function _withdrawFromVaults(uint256 amount) internal {
        // First use idle assets
        uint256 idle = LibNexusVault.idleAssets();
        if (idle >= amount) {
            return; // Can satisfy from idle
        }

        uint256 remaining = amount - idle;

        (address[] memory vaults, uint256[] memory amounts) =
            LibNexusVault.calculateWithdrawAllocation(remaining);

        uint256 length = vaults.length;
        for (uint256 i = 0; i < length; ) {
            if (amounts[i] > 0) {
                IERC4626(vaults[i]).withdraw(amounts[i], address(this), address(this));
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Mint shares to an address
     * @param to Recipient address
     * @param amount Amount of shares to mint
     */
    function _mint(address to, uint256 amount) internal {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        s.totalSupply += amount;
        unchecked {
            s.balances[to] += amount;
        }

        emit Transfer(address(0), to, amount);
    }

    /**
     * @notice Burn shares from an address
     * @param from Address to burn from
     * @param amount Amount of shares to burn
     */
    function _burn(address from, uint256 amount) internal {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        s.balances[from] -= amount;
        unchecked {
            s.totalSupply -= amount;
        }

        emit Transfer(from, address(0), amount);
    }

    /// @notice ERC20 Transfer event (needed for mint/burn)
    event Transfer(address indexed from, address indexed to, uint256 value);
}
