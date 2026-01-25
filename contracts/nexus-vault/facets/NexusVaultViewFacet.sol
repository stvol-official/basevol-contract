// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { LibNexusVaultStorage } from "../libraries/LibNexusVaultStorage.sol";
import { LibNexusVaultAuth } from "../libraries/LibNexusVaultAuth.sol";
import { LibNexusVault } from "../libraries/LibNexusVault.sol";

/**
 * @title NexusVaultViewFacet
 * @author BaseVol Team
 * @notice Read-only view functions for NexusVault
 * @dev Implements all ERC4626 view functions plus NexusVault-specific queries
 *
 * Categories:
 * - ERC4626 Standard Views: asset, totalAssets, convert*, preview*, max*
 * - Vault Registry Views: getVaults, getVaultConfig, assetsInVault
 * - Fee Views: getFeeConfig, pendingFees
 * - Rebalance Views: getAllocationStatus, getRebalanceConfig, needsRebalance
 * - Access Control Views: admin, getKeepers, isKeeper
 * - State Views: paused, isShutdown, getDepositCaps
 */
contract NexusVaultViewFacet {
    /*//////////////////////////////////////////////////////////////
                            ERC4626 VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the underlying asset address
     * @return The asset token address
     */
    function asset() external view returns (address) {
        return address(LibNexusVaultStorage.layout().asset);
    }

    /**
     * @notice Get total assets under management
     * @dev Includes idle assets plus assets in all underlying vaults
     * @return Total assets
     */
    function totalAssets() external view returns (uint256) {
        return LibNexusVault.totalAssets();
    }

    /**
     * @notice Convert assets to shares
     * @param assets Amount of assets
     * @return shares Equivalent shares (rounded down)
     */
    function convertToShares(uint256 assets) external view returns (uint256) {
        return LibNexusVault.convertToShares(assets);
    }

    /**
     * @notice Convert shares to assets
     * @param shares Amount of shares
     * @return assets Equivalent assets (rounded down)
     */
    function convertToAssets(uint256 shares) external view returns (uint256) {
        return LibNexusVault.convertToAssets(shares);
    }

    /**
     * @notice Preview shares received for a deposit
     * @dev Accounts for deposit fee
     * @param assets Assets to deposit
     * @return shares Shares that would be minted
     */
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return LibNexusVault.previewDeposit(assets);
    }

    /**
     * @notice Preview assets required to mint shares
     * @dev Accounts for deposit fee
     * @param shares Shares to mint
     * @return assets Assets required
     */
    function previewMint(uint256 shares) external view returns (uint256) {
        return LibNexusVault.previewMint(shares);
    }

    /**
     * @notice Preview shares burned for withdrawing assets
     * @dev Accounts for withdraw fee
     * @param assets Assets to withdraw
     * @return shares Shares that would be burned
     */
    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return LibNexusVault.previewWithdraw(assets);
    }

    /**
     * @notice Preview assets received for redeeming shares
     * @dev Accounts for withdraw fee
     * @param shares Shares to redeem
     * @return assets Assets that would be received
     */
    function previewRedeem(uint256 shares) external view returns (uint256) {
        return LibNexusVault.previewRedeem(shares);
    }

    /**
     * @notice Get maximum deposit amount for receiver
     * @dev Considers pause state and deposit caps
     * @param receiver Potential receiver
     * @return Maximum depositable assets
     */
    function maxDeposit(address receiver) external view returns (uint256) {
        return LibNexusVault.maxDeposit(receiver);
    }

    /**
     * @notice Get maximum mint amount for receiver
     * @param receiver Potential receiver
     * @return Maximum mintable shares
     */
    function maxMint(address receiver) external view returns (uint256) {
        return LibNexusVault.maxMint(receiver);
    }

    /**
     * @notice Get maximum withdraw amount for owner
     * @dev Only limited by owner's balance
     * @param owner Share owner
     * @return Maximum withdrawable assets
     */
    function maxWithdraw(address owner) external view returns (uint256) {
        return LibNexusVault.maxWithdraw(owner);
    }

    /**
     * @notice Get maximum redeem amount for owner
     * @param owner Share owner
     * @return Maximum redeemable shares
     */
    function maxRedeem(address owner) external view returns (uint256) {
        return LibNexusVault.maxRedeem(owner);
    }

    /*//////////////////////////////////////////////////////////////
                            VAULT REGISTRY VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get all registered vault addresses
     * @return Array of vault addresses
     */
    function getVaults() external view returns (address[] memory) {
        return LibNexusVaultStorage.layout().vaultList;
    }

    /**
     * @notice Get only active vault addresses
     * @return vaults Array of active vault addresses
     */
    function getActiveVaults() external view returns (address[] memory vaults) {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        uint256 activeCount = s.activeVaultCount;
        vaults = new address[](activeCount);

        address[] storage vaultList = s.vaultList;
        uint256 length = vaultList.length;
        uint256 idx = 0;

        for (uint256 i = 0; i < length; ) {
            address vault = vaultList[i];
            if (s.vaultConfigs[vault].isActive) {
                vaults[idx] = vault;
                idx++;
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Get vault count
     * @return Total number of registered vaults
     */
    function vaultCount() external view returns (uint256) {
        return LibNexusVaultStorage.layout().vaultList.length;
    }

    /**
     * @notice Get active vault count
     * @return Number of active vaults
     */
    function activeVaultCount() external view returns (uint256) {
        return LibNexusVaultStorage.layout().activeVaultCount;
    }

    /**
     * @notice Get assets in a specific vault
     * @param vault Vault address
     * @return Assets withdrawable from this vault
     */
    function assetsInVault(address vault) external view returns (uint256) {
        return LibNexusVault.assetsInVault(vault);
    }

    /**
     * @notice Get idle assets not deployed to vaults
     * @return Idle assets in NexusVault contract
     */
    function idleAssets() external view returns (uint256) {
        return LibNexusVault.idleAssets();
    }

    /**
     * @notice Get configuration for a specific vault
     * @param vault Vault address
     * @return targetWeight Target allocation weight
     * @return currentWeight Current allocation weight
     * @return assets Assets in this vault
     * @return isActive Whether vault is active
     */
    function getVaultConfig(
        address vault
    )
        external
        view
        returns (
            uint256 targetWeight,
            uint256 currentWeight,
            uint256 assets,
            bool isActive
        )
    {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();
        LibNexusVaultStorage.VaultConfig storage config = s.vaultConfigs[vault];

        targetWeight = config.targetWeight;
        currentWeight = LibNexusVault.currentWeight(vault);
        assets = LibNexusVault.assetsInVault(vault);
        isActive = config.isActive;
    }

    /**
     * @notice Get full vault config struct
     * @param vault Vault address
     * @return config Full vault configuration
     */
    function getVaultConfigFull(
        address vault
    ) external view returns (LibNexusVaultStorage.VaultConfig memory config) {
        return LibNexusVaultStorage.layout().vaultConfigs[vault];
    }

    /*//////////////////////////////////////////////////////////////
                            ALLOCATION VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get current allocation status for all active vaults
     * @return vaults Array of active vault addresses
     * @return currentWeights Current allocation weights
     * @return targetWeights Target allocation weights
     * @return deviations Deviation from target (positive = over-allocated)
     */
    function getAllocationStatus()
        external
        view
        returns (
            address[] memory vaults,
            uint256[] memory currentWeights,
            uint256[] memory targetWeights,
            int256[] memory deviations
        )
    {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        uint256 activeCount = s.activeVaultCount;
        vaults = new address[](activeCount);
        currentWeights = new uint256[](activeCount);
        targetWeights = new uint256[](activeCount);
        deviations = new int256[](activeCount);

        address[] storage vaultList = s.vaultList;
        uint256 length = vaultList.length;
        uint256 idx = 0;

        for (uint256 i = 0; i < length; ) {
            address vault = vaultList[i];
            if (s.vaultConfigs[vault].isActive) {
                vaults[idx] = vault;
                currentWeights[idx] = LibNexusVault.currentWeight(vault);
                targetWeights[idx] = s.vaultConfigs[vault].targetWeight;
                deviations[idx] =
                    int256(currentWeights[idx]) -
                    int256(targetWeights[idx]);
                idx++;
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Check if rebalancing is needed
     * @dev Returns true if any vault exceeds deviation threshold
     * @return True if rebalance should be triggered
     */
    function needsRebalance() external view returns (bool) {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        if (s.activeVaultCount == 0) return false;

        uint256 total = LibNexusVault.totalAssets();
        if (total == 0) return false;

        uint256 threshold = s.rebalanceConfig.rebalanceThreshold;
        address[] storage vaultList = s.vaultList;
        uint256 length = vaultList.length;

        for (uint256 i = 0; i < length; ) {
            address vault = vaultList[i];
            if (s.vaultConfigs[vault].isActive) {
                uint256 currentWt = LibNexusVault.currentWeight(vault);
                uint256 targetWt = s.vaultConfigs[vault].targetWeight;

                uint256 deviation = currentWt > targetWt
                    ? currentWt - targetWt
                    : targetWt - currentWt;

                if (deviation > threshold) {
                    return true;
                }
            }
            unchecked {
                ++i;
            }
        }

        return false;
    }

    /*//////////////////////////////////////////////////////////////
                            FEE VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get fee configuration
     * @return managementFee Annual management fee (1e18 = 100%)
     * @return performanceFee Performance fee on profits (1e18 = 100%)
     * @return depositFee Deposit fee (1e18 = 100%)
     * @return withdrawFee Withdrawal fee (1e18 = 100%)
     * @return feeRecipient Fee recipient address
     */
    function getFeeConfig()
        external
        view
        returns (
            uint256 managementFee,
            uint256 performanceFee,
            uint256 depositFee,
            uint256 withdrawFee,
            address feeRecipient
        )
    {
        LibNexusVaultStorage.FeeConfig storage config =
            LibNexusVaultStorage.layout().feeConfig;

        return (
            config.managementFee,
            config.performanceFee,
            config.depositFee,
            config.withdrawFee,
            config.feeRecipient
        );
    }

    /**
     * @notice Get pending fees to be collected
     * @return managementFee Pending management fee in assets
     * @return performanceFee Pending performance fee in assets
     */
    function pendingFees()
        external
        view
        returns (uint256 managementFee, uint256 performanceFee)
    {
        return LibNexusVault.pendingFees();
    }

    /**
     * @notice Get high water mark for performance fee
     * @return High water mark value
     */
    function highWaterMark() external view returns (uint256) {
        return LibNexusVaultStorage.layout().highWaterMark;
    }

    /**
     * @notice Get last fee collection timestamp
     * @return Timestamp of last fee collection
     */
    function lastFeeTimestamp() external view returns (uint256) {
        return LibNexusVaultStorage.layout().lastFeeTimestamp;
    }

    /*//////////////////////////////////////////////////////////////
                            REBALANCE CONFIG VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get rebalance configuration
     * @return threshold Deviation threshold (1e18 = 100%)
     * @return maxSlippage Maximum slippage (1e18 = 100%)
     * @return cooldownPeriod Cooldown period in seconds
     * @return lastRebalanceTime Last rebalance timestamp
     */
    function getRebalanceConfig()
        external
        view
        returns (
            uint256 threshold,
            uint256 maxSlippage,
            uint256 cooldownPeriod,
            uint256 lastRebalanceTime
        )
    {
        LibNexusVaultStorage.RebalanceConfig storage config =
            LibNexusVaultStorage.layout().rebalanceConfig;

        return (
            config.rebalanceThreshold,
            config.maxSlippage,
            config.cooldownPeriod,
            config.lastRebalanceTime
        );
    }

    /*//////////////////////////////////////////////////////////////
                            ACCESS CONTROL VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get owner address
     * @return Owner address
     */
    function owner() external view returns (address) {
        return LibNexusVaultStorage.layout().owner;
    }

    /**
     * @notice Get admin address
     * @return Admin address
     */
    function admin() external view returns (address) {
        return LibNexusVaultStorage.layout().admin;
    }

    /**
     * @notice Get list of keepers
     * @return Array of keeper addresses
     */
    function getKeepers() external view returns (address[] memory) {
        return LibNexusVaultStorage.layout().keepers;
    }

    /**
     * @notice Check if address is a keeper
     * @param account Address to check
     * @return True if address is a keeper (or admin/owner)
     */
    function isKeeper(address account) external view returns (bool) {
        return LibNexusVaultAuth.isKeeper(account);
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Check if vault is paused
     * @return True if paused
     */
    function paused() external view returns (bool) {
        return LibNexusVaultStorage.layout().paused;
    }

    /**
     * @notice Check if vault is shutdown
     * @return True if shutdown
     */
    function isShutdown() external view returns (bool) {
        return LibNexusVaultStorage.layout().shutdown;
    }

    /**
     * @notice Get deposit caps
     * @return totalCap Maximum total deposits (0 = unlimited)
     * @return userCap Maximum per-user deposits (0 = unlimited)
     */
    function getDepositCaps()
        external
        view
        returns (uint256 totalCap, uint256 userCap)
    {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();
        return (s.totalDepositCap, s.userDepositCap);
    }

    /*//////////////////////////////////////////////////////////////
                            TRACKING VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get historical deposit total
     * @return Total deposited assets
     */
    function totalDeposited() external view returns (uint256) {
        return LibNexusVaultStorage.layout().totalDeposited;
    }

    /**
     * @notice Get historical withdrawal total
     * @return Total withdrawn assets
     */
    function totalWithdrawn() external view returns (uint256) {
        return LibNexusVaultStorage.layout().totalWithdrawn;
    }
}
