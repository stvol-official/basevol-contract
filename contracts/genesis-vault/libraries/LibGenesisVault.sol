// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibGenesisVaultStorage } from "./LibGenesisVaultStorage.sol";
import { IGenesisStrategy } from "../../core/vault/interfaces/IGenesisStrategy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title IBaseVol
 * @notice Interface for BaseVol contract
 */
interface IBaseVol {
  function currentEpoch() external view returns (uint256);
}

/**
 * @title LibGenesisVault
 * @notice Core vault logic for GenesisVault (ERC4626-based with custom accounting)
 * @dev Handles totalAssets calculation, asset/share conversions, and epoch-based accounting
 *      This is NOT pure ERC4626 due to async deposit/redeem mechanics (ERC7540)
 */
library LibGenesisVault {
  using SafeERC20 for IERC20;
  using Math for uint256;

  // ============ Custom Errors ============
  error BaseVolContractNotSet();

  // ============ Events ============
  event FeesTransferred(address indexed recipient, uint256 amount, string feeType);

  /**
   * @notice Get current epoch from BaseVol contract
   * @dev CRITICAL: Reverts if BaseVol not set or call fails (no fallback)
   * @return Current epoch number
   */
  function getCurrentEpoch() internal view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    address baseVolContract = s.baseVolContract;

    // If BaseVol contract is not set, revert
    if (baseVolContract == address(0)) {
      revert BaseVolContractNotSet();
    }

    // Call BaseVol contract to get real-time current epoch
    try IBaseVol(baseVolContract).currentEpoch() returns (uint256 currentEpoch) {
      return currentEpoch;
    } catch {
      revert BaseVolContractNotSet();
    }
  }

  /**
   * @notice Calculate total assets (idle + strategy - claimableWithdraw)
   * @dev Custom implementation for ERC7540 async vault:
   *      - Excludes ALL unminted deposits (pending + claimable, not yet "in" the vault)
   *      - Excludes claimable withdrawals (already "out" of the vault)
   *      Uses trySub for safe underflow protection
   * @return Total assets available in the vault
   */
  function totalAssets() internal view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    // Get idle assets (balance - unminted deposits) using trySub for safety
    uint256 totalBalance = s.asset.balanceOf(address(this));
    uint256 totalUnmintedDeposits = _totalUnmintedDeposits();
    (, uint256 idle) = totalBalance.trySub(totalUnmintedDeposits);

    // Get strategy assets
    uint256 strategyAssets = s.strategy != address(0)
      ? IGenesisStrategy(s.strategy).totalAssetsUnderManagement()
      : 0;

    // Get total claimable withdrawals
    uint256 claimable = _totalClaimableWithdraw();

    // Return (idle + strategy - claimable) using trySub for safety
    (, uint256 totalAssetsResult) = (idle + strategyAssets).trySub(claimable);
    return totalAssetsResult;
  }

  /**
   * @notice Convert shares to assets (ERC4626)
   * @dev Uses OpenZeppelin's inflation attack resistant formula:
   *      shares * (totalAssets + 1) / (totalSupply + decimalsOffset)
   *      The +1 and +decimalsOffset protect against donation/inflation attacks
   *      IMPORTANT: Uses effective total supply (including pending redeem shares)
   *      to maintain consistency with share price calculations
   * @param shares The amount of shares to convert
   * @return The equivalent amount of assets
   */
  function convertToAssets(uint256 shares) internal view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    // Use effective total supply (actual supply + pending redeems)
    // This ensures consistency with share price calculations
    uint256 supply = s.totalSupply + _totalPendingRedeemShares();
    uint256 assets = totalAssets();

    // OpenZeppelin approach: No explicit zero check needed
    // When supply=0 and assets=0: shares * 1 / 1 = shares (1:1 ratio)
    // When supply=0 and assets>0: shares * (assets+1) / 1 (protects against inflation attack)
    return (shares * (assets + 1)) / (supply + 1);
  }

  /**
   * @notice Convert assets to shares (ERC4626)
   * @dev Uses OpenZeppelin's inflation attack resistant formula:
   *      assets * (totalSupply + decimalsOffset) / (totalAssets + 1)
   *      The +1 and +decimalsOffset protect against donation/inflation attacks
   *      IMPORTANT: Uses effective total supply (including pending redeem shares)
   *      to maintain consistency with share price calculations
   * @param assets The amount of assets to convert
   * @return The equivalent amount of shares
   */
  function convertToShares(uint256 assets) internal view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    // Use effective total supply (actual supply + pending redeems)
    // This ensures consistency with share price calculations
    uint256 supply = s.totalSupply + _totalPendingRedeemShares();
    uint256 totalAssets_ = totalAssets();

    // OpenZeppelin approach: No explicit zero check needed
    // When supply=0 and assets=0: assets * 1 / 1 = assets (1:1 ratio)
    // When supply=0 and assets>0: assets * 1 / (assets+1) ≈ 1 (prevents inflation attack)
    return (assets * (supply + 1)) / (totalAssets_ + 1);
  }

  /**
   * @notice Calculate idle assets (settled assets excluding unminted deposits)
   * @dev Used for liquidity management and settlement calculations
   *      Must exclude ALL deposits where shares haven't been minted (pending + claimable)
   * @return Settled idle assets in the vault
   */
  function idleAssets() internal view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    uint256 totalBalance = s.asset.balanceOf(address(this));
    uint256 totalUnmintedDeposits = _totalUnmintedDeposits();

    // Return total balance minus unminted deposits using trySub for safety
    (, uint256 settledAssets) = totalBalance.trySub(totalUnmintedDeposits);
    return settledAssets;
  }

  /**
   * @notice Calculate total unminted deposits (pending + claimable)
   * @dev GenesisVault custom logic for ERC7540 async deposits
   *      CRITICAL: Must include BOTH pending AND claimable deposits
   *      - Pending: !isSettled, assets received but shares not mintable yet
   *      - Claimable: isSettled but not claimed, assets received but shares not minted yet
   *      Both states mean shares haven't been minted, so assets shouldn't be in totalAssets
   * @return Total assets in unminted deposit state (pending + claimable)
   */
  function _totalUnmintedDeposits() internal view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    uint256 currentEpoch = getCurrentEpoch();
    uint256 totalUnminted = 0;

    for (uint256 i = 0; i < 50 && currentEpoch >= i; i++) {
      uint256 epoch = currentEpoch - i;
      LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];

      // Include ALL deposits where shares haven't been claimed yet
      // This covers both pending (not settled) and claimable (settled but not claimed)
      uint256 requested = roundData.totalRequestedDepositAssets;
      uint256 claimed = roundData.claimedDepositAssets;
      uint256 unminted = requested > claimed ? requested - claimed : 0;

      if (unminted > 0) {
        totalUnminted += unminted;
      }
    }

    return totalUnminted;
  }

  /**
   * @notice Calculate total pending redeem shares across all unsettled epochs
   * @dev GenesisVault custom logic for ERC7540 async redemptions
   *      CRITICAL: These shares are already burned but assets not yet distributed
   *      Must be included in effective total supply for accurate share price
   * @return Total shares in pending redeem state (burned but not yet settled)
   */
  function _totalPendingRedeemShares() internal view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    uint256 currentEpoch = getCurrentEpoch();
    uint256 totalPending = 0;

    for (uint256 i = 0; i < 50 && currentEpoch >= i; i++) {
      uint256 epoch = currentEpoch - i;
      LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];

      // Only include pending (not settled) redeems
      // Claimable redeems are excluded because their assets are already subtracted from totalAssets
      if (!roundData.isSettled && roundData.totalRequestedRedeemShares > 0) {
        totalPending += roundData.totalRequestedRedeemShares;
      }
    }

    return totalPending;
  }

  /**
   * @notice Calculate total claimable withdrawals across all settled epochs
   * @dev GenesisVault custom logic for ERC7540 async redemptions
   * @return Total assets in claimable withdrawal state
   */
  function _totalClaimableWithdraw() internal view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    uint256 currentEpoch = getCurrentEpoch();
    uint256 totalClaimable = 0;

    for (uint256 i = 0; i < 50 && currentEpoch >= i; i++) {
      uint256 epoch = currentEpoch - i;
      LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];

      if (roundData.isSettled) {
        uint256 requested = roundData.totalRequestedRedeemShares;
        uint256 claimed = roundData.claimedRedeemShares;
        uint256 claimableShares = requested > claimed ? requested - claimed : 0;

        if (claimableShares > 0) {
          uint256 claimableAssets = (claimableShares * roundData.sharePrice) / (10 ** s.decimals);
          totalClaimable += claimableAssets;
        }
      }
    }

    return totalClaimable;
  }

  /**
   * @notice Calculate claimable assets/shares for a specific epoch
   * @dev Based on original GenesisVault.sol implementation (lines 1076-1103)
   * @param controller The controller address
   * @param epoch The epoch to check
   * @param isDeposit True for deposit assets, false for redeem shares
   * @return claimable The amount claimable for this epoch
   */
  function calculateClaimableForEpoch(
    address controller,
    uint256 epoch,
    bool isDeposit
  ) internal view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];

    if (!roundData.isSettled) return 0;

    if (isDeposit) {
      uint256 userTotal = s.userEpochDepositAssets[controller][epoch];
      uint256 userClaimed = s.userEpochClaimedDepositAssets[controller][epoch];

      if (userTotal == 0) return 0;

      // Simple and accurate: total - claimed = claimable
      return userTotal > userClaimed ? userTotal - userClaimed : 0;
    } else {
      uint256 userTotal = s.userEpochRedeemShares[controller][epoch];
      uint256 userClaimed = s.userEpochClaimedRedeemShares[controller][epoch];

      if (userTotal == 0) return 0;

      // Simple and accurate: total - claimed = claimable
      return userTotal > userClaimed ? userTotal - userClaimed : 0;
    }
  }

  /**
   * @notice Calculate maximum deposit request amount for a receiver
   * @dev Checks both user-level and vault-level deposit limits
   *      Includes pending deposits in the calculation to prevent exceeding limits
   * @param receiver The address to check deposit limits for
   * @return The maximum amount of assets that can be requested for deposit
   */
  function calculateMaxDepositRequest(address receiver) internal view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    if (s.paused || s.shutdown) {
      return 0;
    }

    uint256 _userDepositLimit = s.userDepositLimit;
    uint256 _vaultDepositLimit = s.vaultDepositLimit;

    // If both limits are max, no restriction
    if (_userDepositLimit == type(uint256).max && _vaultDepositLimit == type(uint256).max) {
      return type(uint256).max;
    }

    // Calculate user's current assets (including pending deposits)
    uint256 userShares = s.balances[receiver];
    uint256 userCurrentAssets = convertToAssets(userShares); // Convert shares to assets

    // Add any pending deposit assets for this user (across last 50 user epochs)
    uint256 userPendingAssets = 0;
    uint256[] memory userEpochs = s.userDepositEpochs[receiver];
    uint256 epochsToCheck = userEpochs.length > 50 ? 50 : userEpochs.length;

    for (uint256 i = 0; i < epochsToCheck; i++) {
      uint256 epoch = userEpochs[userEpochs.length - 1 - i];
      if (!s.roundData[epoch].isSettled) {
        userPendingAssets += s.userEpochDepositAssets[receiver][epoch];
      }
    }

    uint256 userTotalAssets = userCurrentAssets + userPendingAssets;

    // Calculate available user limit
    uint256 remainingUserLimit = _userDepositLimit > userTotalAssets
      ? _userDepositLimit - userTotalAssets
      : 0;

    // Calculate available vault limit
    uint256 vaultTotalAssets = totalAssets();
    uint256 remainingVaultLimit = _vaultDepositLimit > vaultTotalAssets
      ? _vaultDepositLimit - vaultTotalAssets
      : 0;

    // Return the minimum of the two limits
    return remainingUserLimit < remainingVaultLimit ? remainingUserLimit : remainingVaultLimit;
  }

  /**
   * @notice Transfer fees to the designated fee recipient
   * @dev If amount is 0 or recipient is not set, the transfer is skipped
   * @param amount The amount of fees to transfer
   * @param feeType A string describing the type of fee being transferred
   */
  function transferFeesToRecipient(uint256 amount, string memory feeType) internal {
    if (amount == 0) return;

    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    address recipient = s.feeRecipient;

    // If no fee recipient set, skip transfer
    if (recipient == address(0)) {
      return;
    }

    // Transfer fees to recipient
    s.asset.safeTransfer(recipient, amount);

    // Emit event
    emit FeesTransferred(recipient, amount, feeType);
  }
}
