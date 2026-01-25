// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { LibNexusVaultStorage } from "./LibNexusVaultStorage.sol";
import "../errors/NexusVaultErrors.sol";

/**
 * @title LibNexusVault
 * @author BaseVol Team
 * @notice Core calculation and helper library for NexusVault
 * @dev Provides reusable logic for asset/share conversions, allocation calculations,
 *      and fee computations used across multiple facets.
 *
 * Key responsibilities:
 * - Asset and share conversion calculations
 * - Preview functions for deposits/withdrawals
 * - Max deposit/withdraw calculations
 * - Vault allocation and weight calculations
 * - Fee calculations (management, performance, deposit, withdraw)
 */
library LibNexusVault {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Precision for percentage calculations (1e18 = 100%)
    uint256 internal constant FLOAT_PRECISION = 1e18;

    /// @dev Seconds in a year for management fee calculation
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /*//////////////////////////////////////////////////////////////
                            ASSET CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculate total assets across all underlying vaults plus idle
     * @dev Sum of:
     *      - Idle assets held in NexusVault contract
     *      - Assets withdrawable from each active underlying vault
     * @return total Total assets under management
     */
    function totalAssets() internal view returns (uint256 total) {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        // Add idle assets held directly by NexusVault
        total = IERC20(address(s.asset)).balanceOf(address(this));

        // Add assets from all active underlying vaults
        address[] storage vaultList = s.vaultList;
        uint256 length = vaultList.length;

        for (uint256 i = 0; i < length; ) {
            address vault = vaultList[i];
            if (s.vaultConfigs[vault].isActive) {
                // maxWithdraw gives us the actual withdrawable amount
                total += IERC4626(vault).maxWithdraw(address(this));
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Get assets in a specific underlying vault
     * @param vault Vault address to query
     * @return Assets withdrawable from this vault
     */
    function assetsInVault(address vault) internal view returns (uint256) {
        return IERC4626(vault).maxWithdraw(address(this));
    }

    /**
     * @notice Get idle assets not deployed to any vault
     * @return Idle asset balance in NexusVault contract
     */
    function idleAssets() internal view returns (uint256) {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();
        return IERC20(address(s.asset)).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                            SHARE CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Convert assets to shares
     * @dev Uses floor rounding (favorable to vault)
     *      First deposit uses 1:1 ratio
     * @param assets Amount of assets to convert
     * @return shares Equivalent share amount
     */
    function convertToShares(uint256 assets) internal view returns (uint256 shares) {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();
        uint256 supply = s.totalSupply;
        uint256 total = totalAssets();

        if (supply == 0 || total == 0) {
            // First deposit: 1:1 ratio
            shares = assets;
        } else {
            // shares = assets * totalSupply / totalAssets (round down)
            shares = assets.mulDiv(supply, total, Math.Rounding.Floor);
        }
    }

    /**
     * @notice Convert shares to assets
     * @dev Uses floor rounding (favorable to vault)
     * @param shares Amount of shares to convert
     * @return assets Equivalent asset amount
     */
    function convertToAssets(uint256 shares) internal view returns (uint256 assets) {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();
        uint256 supply = s.totalSupply;
        uint256 total = totalAssets();

        if (supply == 0) {
            assets = 0;
        } else {
            // assets = shares * totalAssets / totalSupply (round down)
            assets = shares.mulDiv(total, supply, Math.Rounding.Floor);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            PREVIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Preview shares received for a deposit
     * @dev Accounts for deposit fee if configured
     * @param assets Assets to deposit
     * @return shares Shares that would be minted
     */
    function previewDeposit(uint256 assets) internal view returns (uint256 shares) {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        // Apply deposit fee if configured
        uint256 fee = 0;
        if (s.feeConfig.depositFee > 0) {
            fee = assets.mulDiv(s.feeConfig.depositFee, FLOAT_PRECISION, Math.Rounding.Ceil);
        }
        uint256 netAssets = assets - fee;

        shares = convertToShares(netAssets);
    }

    /**
     * @notice Preview assets required to mint exact shares
     * @dev Accounts for deposit fee if configured
     *      Uses ceiling rounding for assets (user pays more)
     * @param shares Shares to mint
     * @return assets Assets required
     */
    function previewMint(uint256 shares) internal view returns (uint256 assets) {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();
        uint256 supply = s.totalSupply;
        uint256 total = totalAssets();

        // Calculate base assets needed (round up)
        if (supply == 0 || total == 0) {
            assets = shares;
        } else {
            assets = shares.mulDiv(total, supply, Math.Rounding.Ceil);
        }

        // Add deposit fee if configured
        // grossAssets = netAssets / (1 - fee)
        if (s.feeConfig.depositFee > 0) {
            assets = assets.mulDiv(
                FLOAT_PRECISION,
                FLOAT_PRECISION - s.feeConfig.depositFee,
                Math.Rounding.Ceil
            );
        }
    }

    /**
     * @notice Preview shares burned for withdrawing assets
     * @dev Accounts for withdrawal fee if configured
     *      Uses ceiling rounding for shares (user pays more)
     * @param assets Assets to withdraw
     * @return shares Shares that would be burned
     */
    function previewWithdraw(uint256 assets) internal view returns (uint256 shares) {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        // Calculate gross assets needed (including fee)
        // grossAssets = netAssets / (1 - fee)
        uint256 grossAssets = assets;
        if (s.feeConfig.withdrawFee > 0) {
            grossAssets = assets.mulDiv(
                FLOAT_PRECISION,
                FLOAT_PRECISION - s.feeConfig.withdrawFee,
                Math.Rounding.Ceil
            );
        }

        // Convert to shares (round up - user burns more shares)
        uint256 supply = s.totalSupply;
        uint256 total = totalAssets();

        if (supply == 0) {
            shares = 0;
        } else {
            shares = grossAssets.mulDiv(supply, total, Math.Rounding.Ceil);
        }
    }

    /**
     * @notice Preview assets received for redeeming shares
     * @dev Accounts for withdrawal fee if configured
     *      Uses floor rounding for assets (user receives less)
     * @param shares Shares to redeem
     * @return assets Assets that would be received
     */
    function previewRedeem(uint256 shares) internal view returns (uint256 assets) {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        // Convert shares to gross assets
        assets = convertToAssets(shares);

        // Apply withdrawal fee
        if (s.feeConfig.withdrawFee > 0) {
            uint256 fee = assets.mulDiv(
                s.feeConfig.withdrawFee,
                FLOAT_PRECISION,
                Math.Rounding.Ceil
            );
            assets = assets - fee;
        }
    }

    /*//////////////////////////////////////////////////////////////
                            MAX FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculate maximum deposit allowed for a receiver
     * @dev Considers:
     *      - Vault paused/shutdown state
     *      - Total deposit cap
     *      - Per-user deposit cap
     * @param receiver Address that would receive shares
     * @return Maximum assets that can be deposited
     */
    function maxDeposit(address receiver) internal view returns (uint256) {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        // No deposits when paused or shutdown
        if (s.paused || s.shutdown) return 0;

        // No active vaults means no deposits
        if (s.activeVaultCount == 0) return 0;

        uint256 totalCap = s.totalDepositCap;
        uint256 userCap = s.userDepositCap;

        // If both caps are 0, unlimited
        if (totalCap == 0 && userCap == 0) {
            return type(uint256).max;
        }

        uint256 currentTotal = totalAssets();
        uint256 userAssets = convertToAssets(s.balances[receiver]);

        // Calculate remaining capacity
        uint256 totalRemaining = type(uint256).max;
        uint256 userRemaining = type(uint256).max;

        if (totalCap > 0) {
            totalRemaining = currentTotal >= totalCap ? 0 : totalCap - currentTotal;
        }

        if (userCap > 0) {
            userRemaining = userAssets >= userCap ? 0 : userCap - userAssets;
        }

        return totalRemaining < userRemaining ? totalRemaining : userRemaining;
    }

    /**
     * @notice Calculate maximum mint allowed for a receiver
     * @param receiver Address that would receive shares
     * @return Maximum shares that can be minted
     */
    function maxMint(address receiver) internal view returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (maxAssets == type(uint256).max) return type(uint256).max;
        if (maxAssets == 0) return 0;
        return convertToShares(maxAssets);
    }

    /**
     * @notice Calculate maximum withdrawal allowed for an owner
     * @dev Only limited by owner's balance and pause state
     * @param owner Address that owns the shares
     * @return Maximum assets that can be withdrawn
     */
    function maxWithdraw(address owner) internal view returns (uint256) {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        // No withdrawals when paused
        if (s.paused) return 0;

        // Convert owner's shares to assets
        return convertToAssets(s.balances[owner]);
    }

    /**
     * @notice Calculate maximum redeem allowed for an owner
     * @param owner Address that owns the shares
     * @return Maximum shares that can be redeemed
     */
    function maxRedeem(address owner) internal view returns (uint256) {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        // No redemptions when paused
        if (s.paused) return 0;

        return s.balances[owner];
    }

    /*//////////////////////////////////////////////////////////////
                            ALLOCATION HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculate current weight of a vault
     * @param vault Vault address to query
     * @return weight Current weight (1e18 = 100%)
     */
    function currentWeight(address vault) internal view returns (uint256 weight) {
        uint256 total = totalAssets();
        if (total == 0) return 0;

        uint256 vaultAssets = assetsInVault(vault);
        weight = vaultAssets.mulDiv(FLOAT_PRECISION, total);
    }

    /**
     * @notice Calculate deposit allocation across vaults based on target weights
     * @dev Distributes amount proportionally to target weights of active vaults
     *      Last vault receives remainder to handle rounding
     * @param amount Total amount to distribute
     * @return vaults Array of vault addresses to receive deposits
     * @return amounts Array of amounts for each vault
     */
    function calculateDepositAllocation(
        uint256 amount
    ) internal view returns (address[] memory vaults, uint256[] memory amounts) {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        uint256 activeCount = s.activeVaultCount;
        if (activeCount == 0) {
            // No vaults, keep as idle
            return (new address[](0), new uint256[](0));
        }

        vaults = new address[](activeCount);
        amounts = new uint256[](activeCount);

        // First pass: collect active vaults and total weight
        address[] storage vaultList = s.vaultList;
        uint256 length = vaultList.length;
        uint256 totalWeight = 0;
        uint256 idx = 0;

        for (uint256 i = 0; i < length; ) {
            address vault = vaultList[i];
            if (s.vaultConfigs[vault].isActive) {
                vaults[idx] = vault;
                totalWeight += s.vaultConfigs[vault].targetWeight;
                idx++;
            }
            unchecked {
                ++i;
            }
        }

        // Second pass: allocate based on normalized weights
        uint256 allocated = 0;
        for (uint256 i = 0; i < activeCount; ) {
            if (i == activeCount - 1) {
                // Last vault gets remainder (handles rounding)
                amounts[i] = amount - allocated;
            } else {
                amounts[i] = amount.mulDiv(
                    s.vaultConfigs[vaults[i]].targetWeight,
                    totalWeight
                );
                allocated += amounts[i];
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Calculate proportional withdrawal from vaults
     * @dev First uses idle assets, then withdraws proportionally from vaults
     *      based on current allocation (not target weights)
     * @param amount Total amount to withdraw
     * @return vaults Array of vault addresses to withdraw from
     * @return amounts Array of amounts to withdraw from each vault
     */
    function calculateWithdrawAllocation(
        uint256 amount
    ) internal view returns (address[] memory vaults, uint256[] memory amounts) {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        // First, check idle assets
        uint256 idle = idleAssets();
        if (idle >= amount) {
            // Can satisfy entirely from idle
            return (new address[](0), new uint256[](0));
        }

        uint256 remaining = amount - idle;

        // Get total assets in vaults (excluding idle)
        uint256 totalInVaults = 0;
        address[] storage vaultList = s.vaultList;
        uint256 length = vaultList.length;
        uint256 activeCount = s.activeVaultCount;

        // Collect vault assets
        uint256[] memory vaultAssets = new uint256[](activeCount);
        vaults = new address[](activeCount);
        amounts = new uint256[](activeCount);

        uint256 idx = 0;
        for (uint256 i = 0; i < length; ) {
            address vault = vaultList[i];
            if (s.vaultConfigs[vault].isActive) {
                vaults[idx] = vault;
                vaultAssets[idx] = assetsInVault(vault);
                totalInVaults += vaultAssets[idx];
                idx++;
            }
            unchecked {
                ++i;
            }
        }

        // Allocate proportionally based on current holdings
        uint256 withdrawn = 0;
        for (uint256 i = 0; i < activeCount; ) {
            if (i == activeCount - 1) {
                // Last vault gets remainder
                amounts[i] = remaining - withdrawn;
            } else if (totalInVaults > 0) {
                // Proportional withdrawal
                amounts[i] = remaining.mulDiv(vaultAssets[i], totalInVaults);
                withdrawn += amounts[i];
            }
            unchecked {
                ++i;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            FEE CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculate pending management fee
     * @dev Management fee accrues over time based on total assets
     *      Formula: totalAssets * annualFee * timeElapsed / secondsPerYear
     * @return feeAmount Fee amount in assets
     * @return feeShares Fee amount converted to shares
     */
    function calculateManagementFee()
        internal
        view
        returns (uint256 feeAmount, uint256 feeShares)
    {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        uint256 timeElapsed = block.timestamp - s.lastFeeTimestamp;
        if (timeElapsed == 0 || s.feeConfig.managementFee == 0) {
            return (0, 0);
        }

        uint256 total = totalAssets();
        if (total == 0) return (0, 0);

        // Calculate fee amount
        // feeAmount = totalAssets * annualFee * timeElapsed / (FLOAT_PRECISION * SECONDS_PER_YEAR)
        feeAmount = total
            .mulDiv(s.feeConfig.managementFee, FLOAT_PRECISION)
            .mulDiv(timeElapsed, SECONDS_PER_YEAR);

        // Convert to shares
        if (s.totalSupply > 0 && total > 0) {
            feeShares = feeAmount.mulDiv(s.totalSupply, total);
        }
    }

    /**
     * @notice Calculate pending performance fee based on high water mark
     * @dev Only charges fee on profits above the high water mark
     *      Formula: (currentAssets - highWaterMark) * performanceFee
     * @return feeAmount Fee amount in assets
     * @return feeShares Fee amount converted to shares
     * @return newHighWaterMark Updated high water mark
     */
    function calculatePerformanceFee()
        internal
        view
        returns (uint256 feeAmount, uint256 feeShares, uint256 newHighWaterMark)
    {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        uint256 total = totalAssets();
        uint256 hwm = s.highWaterMark;

        // No fee if below or at high water mark
        if (total <= hwm || s.feeConfig.performanceFee == 0) {
            return (0, 0, hwm);
        }

        // Calculate fee on profit
        uint256 profit = total - hwm;
        feeAmount = profit.mulDiv(s.feeConfig.performanceFee, FLOAT_PRECISION);

        // Convert to shares
        if (s.totalSupply > 0 && total > 0) {
            feeShares = feeAmount.mulDiv(s.totalSupply, total);
        }

        // New HWM is current total assets
        newHighWaterMark = total;
    }

    /**
     * @notice Get total pending fees
     * @return managementFee Pending management fee in assets
     * @return performanceFee Pending performance fee in assets
     */
    function pendingFees()
        internal
        view
        returns (uint256 managementFee, uint256 performanceFee)
    {
        (managementFee, ) = calculateManagementFee();
        (performanceFee, , ) = calculatePerformanceFee();
    }
}
