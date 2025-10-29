// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibGenesisVaultStorage } from "../libraries/LibGenesisVaultStorage.sol";
import { LibGenesisVault } from "../libraries/LibGenesisVault.sol";
import { LibDiamond } from "../../diamond-common/libraries/LibDiamond.sol";
import { IGenesisStrategy } from "../../core/vault/interfaces/IGenesisStrategy.sol";
import { IERC7540 } from "../../core/vault/interfaces/IERC7540.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title GenesisVaultViewFacet
 * @notice View functions for GenesisVault Diamond
 */
contract GenesisVaultViewFacet {
  using Math for uint256;

  // ============ Core View Functions ============

  /**
   * @notice Get underlying asset address
   */
  function asset() external view returns (address) {
    return address(LibGenesisVaultStorage.layout().asset);
  }

  /**
   * @notice Get shutdown status
   */
  function isShutdown() external view returns (bool) {
    return LibGenesisVaultStorage.layout().shutdown;
  }

  /**
   * @notice Get paused status
   */
  function paused() external view returns (bool) {
    return LibGenesisVaultStorage.layout().paused;
  }

  /**
   * @notice Get contract owner
   */
  function owner() external view returns (address) {
    return LibDiamond.contractOwner();
  }

  /**
   * @notice Get admin address
   */
  function admin() external view returns (address) {
    return LibGenesisVaultStorage.layout().admin;
  }

  /**
   * @notice Get BaseVol contract address
   */
  function baseVolContract() external view returns (address) {
    return LibGenesisVaultStorage.layout().baseVolContract;
  }

  /**
   * @notice Get strategy address
   */
  function strategy() external view returns (address) {
    return LibGenesisVaultStorage.layout().strategy;
  }

  /**
   * @notice Get ClearingHouse contract address
   */
  function clearingHouse() external view returns (address) {
    return LibGenesisVaultStorage.layout().clearingHouse;
  }

  // ============ Fee View Functions ============

  /**
   * @notice Get entry cost
   */
  function entryCost() external view returns (uint256) {
    return LibGenesisVaultStorage.layout().entryCost;
  }

  /**
   * @notice Get exit cost
   */
  function exitCost() external view returns (uint256) {
    return LibGenesisVaultStorage.layout().exitCost;
  }

  /**
   * @notice Get management fee
   */
  function managementFee() external view returns (uint256) {
    return LibGenesisVaultStorage.layout().managementFee;
  }

  /**
   * @notice Get performance fee
   */
  function performanceFee() external view returns (uint256) {
    return LibGenesisVaultStorage.layout().performanceFee;
  }

  /**
   * @notice Get hurdle rate
   */
  function hurdleRate() external view returns (uint256) {
    return LibGenesisVaultStorage.layout().hurdleRate;
  }

  /**
   * @notice Get fee recipient
   */
  function feeRecipient() external view returns (address) {
    return LibGenesisVaultStorage.layout().feeRecipient;
  }

  /**
   * @notice Get user deposit limit
   */
  function userDepositLimit() external view returns (uint256) {
    return LibGenesisVaultStorage.layout().userDepositLimit;
  }

  /**
   * @notice Get vault deposit limit
   */
  function vaultDepositLimit() external view returns (uint256) {
    return LibGenesisVaultStorage.layout().vaultDepositLimit;
  }

  /**
   * @notice Get management fee data
   */
  function getManagementFeeData()
    external
    view
    returns (uint256 lastFeeTimestamp, uint256 totalFeesCollected, address recipient)
  {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    return (
      s.managementFeeData.lastFeeTimestamp,
      s.managementFeeData.totalFeesCollected,
      s.feeRecipient
    );
  }

  /**
   * @notice Get user performance data
   */
  function getUserPerformanceData(
    address user
  ) external view returns (uint256 waep, uint256 totalShares, uint256 lastUpdateEpoch) {
    LibGenesisVaultStorage.UserPerformanceData storage data = LibGenesisVaultStorage
      .layout()
      .userPerformanceData[user];
    return (data.waep, data.totalShares, data.lastUpdateEpoch);
  }

  // ============ Round/Epoch View Functions ============

  /**
   * @notice Get round data for a specific epoch
   */
  function roundData(
    uint256 epoch
  ) external view returns (LibGenesisVaultStorage.RoundData memory) {
    return LibGenesisVaultStorage.layout().roundData[epoch];
  }

  /**
   * @notice Get user's deposit epochs
   */
  function getUserDepositEpochs(address user) external view returns (uint256[] memory) {
    return LibGenesisVaultStorage.layout().userDepositEpochs[user];
  }

  /**
   * @notice Get user's redeem epochs
   */
  function getUserRedeemEpochs(address user) external view returns (uint256[] memory) {
    return LibGenesisVaultStorage.layout().userRedeemEpochs[user];
  }

  /**
   * @notice Get users who deposited in an epoch
   */
  function getEpochDepositUsers(uint256 epoch) external view returns (address[] memory) {
    return LibGenesisVaultStorage.layout().epochDepositUsers[epoch];
  }

  /**
   * @notice Get users who redeemed in an epoch
   */
  function getEpochRedeemUsers(uint256 epoch) external view returns (address[] memory) {
    return LibGenesisVaultStorage.layout().epochRedeemUsers[epoch];
  }

  /**
   * @notice Get current epoch from BaseVol contract
   * @dev CRITICAL: Reverts if BaseVol not set or call fails (no fallback)
   */
  function getCurrentEpoch() public view returns (uint256) {
    return LibGenesisVault.getCurrentEpoch();
  }

  // ============ Asset Calculation View Functions ============

  /**
   * @notice Get idle assets (not deployed to strategy)
   * @dev Returns settled assets only (excludes unminted deposits)
   *      Uses LibGenesisVault.idleAssets() for consistent calculation
   */
  function idleAssets() public view returns (uint256) {
    return LibGenesisVault.idleAssets();
  }

  /**
   * @notice Get total assets (idle + strategy - claimable withdrawals)
   * @dev Uses LibGenesisVault.totalAssets() which correctly:
   *      - Excludes ALL unminted deposits (pending + claimable)
   *      - Excludes claimable withdrawals
   *      This is the correct function for share price calculation
   */
  function totalAssets() public view returns (uint256 assets) {
    return LibGenesisVault.totalAssets();
  }

  /**
   * @notice Returns total claimable redeem assets across all settled epochs
   * @dev This represents assets that users can immediately claim and Strategy needs to prepare for withdrawal
   */
  function totalClaimableWithdraw() public view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    uint256 totalClaimable = 0;

    // Check broader range of epochs with claimable redemptions
    uint256 currentEpoch = LibGenesisVault.getCurrentEpoch();

    // Check last 50 epochs to cover longer settlement periods
    for (uint256 i = 0; i < 50 && currentEpoch >= i; i++) {
      uint256 epoch = currentEpoch - i;
      LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];

      // Only count settled epochs (claimable state)
      if (roundData.isSettled) {
        uint256 requested = roundData.totalRequestedRedeemShares;
        uint256 claimed = roundData.claimedRedeemShares;
        uint256 claimableShares = requested > claimed ? requested - claimed : 0;

        if (claimableShares > 0) {
          // Use epoch-specific share price for accurate calculation
          uint256 claimableAssets = (claimableShares * roundData.sharePrice) / (10 ** s.decimals);
          totalClaimable += claimableAssets;
        }
      }
    }

    return totalClaimable;
  }

  // ============ ERC4626 Conversion Functions ============

  /**
   * @notice Convert shares to assets (ERC4626)
   * @dev Delegates to LibGenesisVaultStorage for consistent conversion logic
   */
  function convertToAssets(uint256 shares) public view returns (uint256) {
    return LibGenesisVault.convertToAssets(shares);
  }

  /**
   * @notice Convert assets to shares (ERC4626)
   * @dev Delegates to LibGenesisVaultStorage for consistent conversion logic
   */
  function convertToShares(uint256 assets) public view returns (uint256) {
    return LibGenesisVault.convertToShares(assets);
  }

  // ============ ERC4626 Max Functions ============

  /**
   * @notice ERC7540 - maxDeposit returns max assets for deposit (claimable)
   */
  function maxDeposit(address receiver) public view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    if (s.paused || s.shutdown) {
      return 0;
    }

    // Return max assets that can be claimed via deposit() function
    return _calculateClaimableDepositAssetsAcrossEpochs(receiver);
  }

  /**
   * @notice ERC7540 - maxMint returns max shares for mint (claimable)
   */
  function maxMint(address receiver) public view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    if (s.paused || s.shutdown) {
      return 0;
    }

    uint256 claimableAssets = _calculateClaimableDepositAssetsAcrossEpochs(receiver);
    if (claimableAssets == 0) {
      return 0;
    }

    return _calculateClaimableSharesFromAssets(receiver, claimableAssets);
  }

  /**
   * @notice Returns the maximum amount of assets that can be requested for deposit
   */
  function maxRequestDeposit(address receiver) public view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    if (s.paused || s.shutdown) {
      return 0;
    }

    return LibGenesisVault.calculateMaxDepositRequest(receiver);
  }

  /**
   * @notice Returns the maximum amount of shares that can be requested for redeem
   */
  function maxRequestRedeem(address owner) public view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    if (s.paused || s.shutdown) {
      return 0;
    }

    return s.balances[owner];
  }

  /**
   * @notice ERC7540 - maxWithdraw returns claimable assets
   */
  function maxWithdraw(address controller) public view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    if (s.paused) {
      return 0;
    }

    return _calculateClaimableRedeemAssetsAcrossEpochs(controller);
  }

  /**
   * @notice ERC7540 - maxRedeem returns claimable shares
   */
  function maxRedeem(address controller) public view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    if (s.paused) {
      return 0;
    }

    return _calculateClaimableRedeemSharesAcrossEpochs(controller);
  }

  // ============ ERC4626 Preview Functions (Revert for ERC7540) ============

  /**
   * @notice ERC7540 - previewDeposit MUST revert for async vaults
   */
  function previewDeposit(uint256) public pure returns (uint256) {
    revert("ERC7540: previewDeposit not supported for async vaults");
  }

  /**
   * @notice ERC7540 - previewMint MUST revert for async vaults
   */
  function previewMint(uint256) public pure returns (uint256) {
    revert("ERC7540: previewMint not supported for async vaults");
  }

  /**
   * @notice ERC7540 - previewWithdraw MUST revert for async vaults
   */
  function previewWithdraw(uint256) public pure returns (uint256) {
    revert("ERC7540: previewWithdraw not supported for async vaults");
  }

  /**
   * @notice ERC7540 - previewRedeem MUST revert for async vaults
   */
  function previewRedeem(uint256) public pure returns (uint256) {
    revert("ERC7540: previewRedeem not supported for async vaults");
  }

  // ============ Internal Helper Functions ============

  /**
   * @notice Calculate claimable deposit assets across epochs
   * @dev Only checks last 50 epochs from current epoch for consistency
   */
  function _calculateClaimableDepositAssetsAcrossEpochs(
    address controller
  ) internal view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    uint256 currentEpoch = LibGenesisVault.getCurrentEpoch();
    uint256 total = 0;

    uint256[] memory userEpochs = s.userDepositEpochs[controller];

    for (uint256 i = 0; i < userEpochs.length; i++) {
      uint256 epoch = userEpochs[i];

      // Only check epochs within last 50 epochs from current epoch
      if (epoch + 50 <= currentEpoch) continue;

      if (s.roundData[epoch].isSettled) {
        uint256 depositedAssets = s.userEpochDepositAssets[controller][epoch];
        uint256 claimedAssets = s.userEpochClaimedDepositAssets[controller][epoch];
        total += (depositedAssets - claimedAssets);
      }
    }

    return total;
  }

  /**
   * @notice Calculate claimable redeem shares across epochs
   * @dev Only checks last 50 epochs from current epoch for consistency
   */
  function _calculateClaimableRedeemSharesAcrossEpochs(
    address controller
  ) internal view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    uint256 currentEpoch = LibGenesisVault.getCurrentEpoch();
    uint256 total = 0;

    uint256[] memory userEpochs = s.userRedeemEpochs[controller];

    for (uint256 i = 0; i < userEpochs.length; i++) {
      uint256 epoch = userEpochs[i];

      // Only check epochs within last 50 epochs from current epoch
      if (epoch + 50 <= currentEpoch) continue;

      if (s.roundData[epoch].isSettled) {
        uint256 redeemedShares = s.userEpochRedeemShares[controller][epoch];
        uint256 claimedShares = s.userEpochClaimedRedeemShares[controller][epoch];
        total += (redeemedShares - claimedShares);
      }
    }

    return total;
  }

  /**
   * @notice Calculate claimable redeem assets across epochs
   * @dev Only checks last 50 epochs from current epoch for consistency
   */
  function _calculateClaimableRedeemAssetsAcrossEpochs(
    address controller
  ) internal view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    uint256 currentEpoch = LibGenesisVault.getCurrentEpoch();
    uint256 total = 0;

    uint256[] memory userEpochs = s.userRedeemEpochs[controller];

    for (uint256 i = 0; i < userEpochs.length; i++) {
      uint256 epoch = userEpochs[i];

      // Only check epochs within last 50 epochs from current epoch
      if (epoch + 50 <= currentEpoch) continue;

      LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];
      if (roundData.isSettled) {
        uint256 redeemedShares = s.userEpochRedeemShares[controller][epoch];
        uint256 claimedShares = s.userEpochClaimedRedeemShares[controller][epoch];
        uint256 claimableShares = redeemedShares - claimedShares;
        total += (claimableShares * roundData.sharePrice) / (10 ** s.decimals);
      }
    }

    return total;
  }

  /**
   * @notice Calculate claimable shares from assets (for maxMint)
   * @dev Only checks last 50 epochs from current epoch for consistency
   */
  function _calculateClaimableSharesFromAssets(
    address controller,
    uint256 claimableAssets
  ) internal view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    uint256 currentEpoch = LibGenesisVault.getCurrentEpoch();
    uint256 totalShares = 0;
    uint256 remainingAssets = claimableAssets;

    uint256[] memory userEpochs = s.userDepositEpochs[controller];

    for (uint256 i = 0; i < userEpochs.length && remainingAssets > 0; i++) {
      uint256 epoch = userEpochs[i];

      // Only check epochs within last 50 epochs from current epoch
      if (epoch + 50 <= currentEpoch) continue;

      LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];

      if (!roundData.isSettled) continue;

      uint256 depositedAssets = s.userEpochDepositAssets[controller][epoch];
      uint256 claimedAssets = s.userEpochClaimedDepositAssets[controller][epoch];
      uint256 claimableAssetsForEpoch = depositedAssets - claimedAssets;
      uint256 assetsToProcess = Math.min(remainingAssets, claimableAssetsForEpoch);

      if (assetsToProcess > 0) {
        uint256 epochShares = (assetsToProcess * (10 ** s.decimals)) / roundData.sharePrice;
        totalShares += epochShares;
        remainingAssets -= assetsToProcess;
      }
    }

    return totalShares;
  }
}
