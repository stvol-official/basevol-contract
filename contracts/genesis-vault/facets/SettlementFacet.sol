// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibGenesisVaultStorage } from "../libraries/LibGenesisVaultStorage.sol";
import { LibGenesisVault } from "../libraries/LibGenesisVault.sol";
import { LibERC20 } from "../libraries/LibERC20.sol";
import { IGenesisStrategy } from "../../core/vault/interfaces/IGenesisStrategy.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title SettlementFacet
 * @notice Handles epoch settlement logic for GenesisVault Diamond
 * @dev Called by keepers when BaseVol rounds settle
 */
contract SettlementFacet {
  using Math for uint256;

  // ============ Events ============
  event RoundSettled(uint256 indexed epoch, uint256 sharePrice);
  event RoundSettlementProcessed(
    uint256 indexed epoch,
    uint256 requiredRedeemAssets,
    uint256 availableAssets,
    bool liquidityRequestMade
  );
  event StrategyLiquidityRequested(uint256 amount);
  event StrategyLiquidityRequestFailed(uint256 amount, string reason);
  event StrategyUtilizationNotified(uint256 idleAssets);
  event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
  event Withdraw(
    address indexed sender,
    address indexed receiver,
    address indexed owner,
    uint256 assets,
    uint256 shares
  );
  event PerformanceFeeCharged(
    address indexed user,
    uint256 feeAmount,
    uint256 currentSharePrice,
    uint256 userWAEP
  );

  // ============ Custom Errors ============
  error RoundAlreadySettled(uint256 epoch);

  // ============ Modifiers ============
  modifier onlyKeeper() {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    bool isKeeper = false;
    for (uint i = 0; i < s.keepers.length; i++) {
      if (s.keepers[i] == msg.sender) {
        isKeeper = true;
        break;
      }
    }
    require(isKeeper, "SettlementFacet: Only keeper");
    _;
  }

  // ============ Settlement Functions ============

  /**
   * @notice Called by keeper when a round/epoch settles in BaseVol
   * @param epoch The epoch that was settled
   */
  function onRoundSettled(uint256 epoch) external onlyKeeper {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];

    if (roundData.isSettled) {
      revert RoundAlreadySettled(epoch);
    }

    // Calculate share price based on vault's current state
    uint256 sharePrice = _calculateCurrentSharePrice();

    roundData.sharePrice = sharePrice;
    roundData.isSettled = true;
    roundData.settlementTimestamp = block.timestamp;
    emit RoundSettled(epoch, sharePrice);

    // CRITICAL: Process management fee BEFORE minting new shares
    // This ensures management fee is only charged on shares that existed during the period
    _mintManagementFeeShares();

    // Process round settlement including liquidity management
    // This will mint new shares to depositors
    _processRoundSettlement(epoch);
  }

  // ============ Internal Settlement Logic ============

  /**
   * @notice Calculate current share price
   */
  function _calculateCurrentSharePrice() internal view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    // If this is the first epoch or vault has no shares, use initial price
    if (s.totalSupply == 0) {
      return (10 ** s.decimals); // 1 share = 1 asset (scaled)
    }

    // Get strategy performance data for this epoch
    address strategyAddress = s.strategy;
    if (strategyAddress == address(0)) {
      // No strategy deployed yet, return 1:1 ratio
      return (10 ** s.decimals);
    }

    // Calculate share price based on vault's current state (uses LibGenesisVault.totalAssets)
    uint256 vaultTotalAssets = LibGenesisVault.totalAssets();

    // Include pending redeem shares in total supply for consistent share price calculation
    uint256 vaultTotalSupply = s.totalSupply + _totalPendingRedeemShares();

    if (vaultTotalSupply == 0) {
      return (10 ** s.decimals);
    }

    // Share price = (total assets per share) scaled by share decimals
    return (vaultTotalAssets * (10 ** s.decimals)) / vaultTotalSupply;
  }

  /**
   * @notice Calculate total pending redeem shares
   */
  function _totalPendingRedeemShares() internal view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    uint256 totalPending = 0;
    uint256 currentEpoch = LibGenesisVault.getCurrentEpoch();

    // Check recent epochs (last 50) for pending redeems
    for (uint256 i = 0; i < 50 && currentEpoch >= i; i++) {
      uint256 epoch = currentEpoch - i;
      LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];

      if (!roundData.isSettled && roundData.totalRequestedRedeemShares > 0) {
        totalPending += roundData.totalRequestedRedeemShares;
      }
    }

    return totalPending;
  }

  /**
   * @notice Process epoch settlement including liquidity management
   */
  function _processRoundSettlement(uint256 epoch) internal {
    // 1. Calculate required assets for redemptions in this epoch
    uint256 requiredRedeemAssets = _calculateRoundRedeemAssets(epoch);

    // 2. Check current available assets
    uint256 availableAssets = LibGenesisVault.idleAssets();

    // 3. Request liquidity from strategy if insufficient
    bool liquidityRequestMade = false;
    if (requiredRedeemAssets > availableAssets) {
      uint256 shortfall = requiredRedeemAssets - availableAssets;
      _requestLiquidityFromStrategy(shortfall);
      liquidityRequestMade = true;
    }

    // 4. Auto-process all user requests for this epoch
    _autoProcessEpochRequests(epoch);

    // 5. Signal strategy for idle asset utilization (async)
    _notifyStrategyForUtilization();

    emit RoundSettlementProcessed(
      epoch,
      requiredRedeemAssets,
      availableAssets,
      liquidityRequestMade
    );
  }

  /**
   * @notice Calculate required assets for redemptions in a specific round
   */
  function _calculateRoundRedeemAssets(uint256 epoch) internal view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];

    if (!roundData.isSettled) return 0;

    uint256 totalRedeemShares = roundData.totalRequestedRedeemShares;
    uint256 claimedShares = roundData.claimedRedeemShares;
    uint256 claimableShares = totalRedeemShares > claimedShares
      ? totalRedeemShares - claimedShares
      : 0;

    if (claimableShares == 0) return 0;

    // Use round-specific share price for accurate asset calculation
    return (claimableShares * roundData.sharePrice) / (10 ** s.decimals);
  }

  /**
   * @notice Request liquidity from strategy
   */
  function _requestLiquidityFromStrategy(uint256 amount) internal {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    address strategyAddr = s.strategy;

    if (strategyAddr == address(0)) {
      emit StrategyLiquidityRequestFailed(amount, "Strategy not set");
      return;
    }

    // Request specific amount of liquidity from strategy
    // Strategy will intelligently source from: 1) idle assets, 2) BaseVol, 3) Morpho
    try IGenesisStrategy(strategyAddr).provideLiquidityForWithdrawals(amount) {
      emit StrategyLiquidityRequested(amount);
    } catch Error(string memory reason) {
      // Strategy call failure should not stop vault settlement
      // Fallback to basic asset processing
      try IGenesisStrategy(strategyAddr).processAssetsToWithdraw() {
        emit StrategyLiquidityRequested(amount);
        emit StrategyLiquidityRequestFailed(
          amount,
          string(abi.encodePacked("Primary method failed: ", reason, " - Used fallback"))
        );
      } catch Error(string memory fallbackReason) {
        // Both methods failed - log the failures and continue
        emit StrategyLiquidityRequestFailed(
          amount,
          string(
            abi.encodePacked(
              "Both methods failed - Primary: ",
              reason,
              " Fallback: ",
              fallbackReason
            )
          )
        );
      } catch {
        // Fallback method failed with unknown error
        emit StrategyLiquidityRequestFailed(
          amount,
          string(abi.encodePacked("Primary failed: ", reason, " - Fallback failed: Unknown error"))
        );
      }
    } catch {
      // Primary method failed with unknown error - try fallback
      try IGenesisStrategy(strategyAddr).processAssetsToWithdraw() {
        emit StrategyLiquidityRequested(amount);
        emit StrategyLiquidityRequestFailed(
          amount,
          "Primary method failed: Unknown error - Used fallback"
        );
      } catch Error(string memory fallbackReason) {
        emit StrategyLiquidityRequestFailed(
          amount,
          string(
            abi.encodePacked(
              "Both methods failed - Primary: Unknown error, Fallback: ",
              fallbackReason
            )
          )
        );
      } catch {
        emit StrategyLiquidityRequestFailed(amount, "Both methods failed with unknown errors");
      }
    }
  }

  /**
   * @notice Auto-process all user requests for this epoch
   */
  function _autoProcessEpochRequests(uint256 epoch) internal {
    _autoProcessEpochRedeems(epoch);
    _autoProcessEpochDeposits(epoch);
  }

  /**
   * @notice Auto-process deposit requests for an epoch
   */
  function _autoProcessEpochDeposits(uint256 epoch) internal {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    address[] memory users = s.epochDepositUsers[epoch];

    for (uint256 i = 0; i < users.length; i++) {
      _autoProcessUserDeposit(users[i], epoch);
    }
  }

  /**
   * @notice Auto-process redeem requests for an epoch
   */
  function _autoProcessEpochRedeems(uint256 epoch) internal {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    address[] memory users = s.epochRedeemUsers[epoch];

    for (uint256 i = 0; i < users.length; i++) {
      _autoProcessUserRedeem(users[i], epoch);
    }
  }

  /**
   * @notice Auto-process user deposit for an epoch
   */
  function _autoProcessUserDeposit(address user, uint256 epoch) internal {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];

    if (!roundData.isSettled) return;

    // Calculate user's claimable assets for this epoch
    uint256 claimableAssets = LibGenesisVault.calculateClaimableForEpoch(user, epoch, true);
    if (claimableAssets == 0) return;

    // Calculate shares to mint using epoch-specific share price
    uint256 sharesToMint = (claimableAssets * (10 ** s.decimals)) / roundData.sharePrice;

    // Update WAEP for the user with epoch-specific share price
    _updateUserWAEP(user, sharesToMint, roundData.sharePrice);

    // Update claimed amounts
    roundData.claimedDepositAssets += claimableAssets;
    s.userEpochClaimedDepositAssets[user][epoch] += claimableAssets;

    // Mint shares to user (controller = receiver in auto-processing)
    LibERC20._mint(user, sharesToMint);

    // Emit deposit event
    emit Deposit(user, user, claimableAssets, sharesToMint);
  }

  /**
   * @notice Auto-process user redeem for an epoch
   */
  function _autoProcessUserRedeem(address user, uint256 epoch) internal {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];

    if (!roundData.isSettled) return;

    // Calculate user's claimable shares for this epoch
    uint256 claimableShares = LibGenesisVault.calculateClaimableForEpoch(user, epoch, false);
    if (claimableShares == 0) return;

    // Calculate assets to transfer using epoch-specific share price
    uint256 grossAssets = (claimableShares * roundData.sharePrice) / (10 ** s.decimals);

    // Calculate and charge performance fee for this redemption
    uint256 performanceFeeAmount = _calculateAndChargePerformanceFee(
      user,
      claimableShares,
      roundData.sharePrice
    );

    // Apply exit cost - user receives net amount after fee deduction
    uint256 exitCostAmount = s.exitCost;
    uint256 netAssets = grossAssets - exitCostAmount - performanceFeeAmount;

    // Transfer exit cost immediately to fee recipient
    LibGenesisVault.transferFeesToRecipient(exitCostAmount, "exit");

    // Update claimed amounts
    roundData.claimedRedeemShares += claimableShares;
    s.userEpochClaimedRedeemShares[user][epoch] += claimableShares;

    // Transfer assets to user (controller = receiver in auto-processing)
    s.asset.transfer(user, netAssets);

    // Emit withdrawal event
    emit Withdraw(address(this), user, user, netAssets, claimableShares);
  }

  /**
   * @notice Signal strategy about idle asset utilization opportunity
   * @dev Strategy's keeperRebalance is only callable by operator
   *      Emit event for keeper to detect and trigger rebalancing
   */
  function _notifyStrategyForUtilization() internal {
    uint256 idleAmount = LibGenesisVault.idleAssets();
    emit StrategyUtilizationNotified(idleAmount);
  }

  /**
   * @notice Mint management fee shares
   */
  function _mintManagementFeeShares() internal {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    LibGenesisVaultStorage.ManagementFeeData storage feeData = s.managementFeeData;

    // Management fee should be calculated on shares that existed during the period
    // This includes pending redeem shares (which were burned at requestRedeem but still exist logically)
    uint256 currentTotalSupply = s.totalSupply + _totalPendingRedeemShares();
    if (currentTotalSupply == 0) return;

    uint256 timeElapsed = block.timestamp - feeData.lastFeeTimestamp;
    if (timeElapsed == 0) return;

    // Skip fee collection if this is the first round after deposits
    // (no shares existed during the time period being charged)
    if (feeData.totalFeesCollected == 0) {
      // First time - just update timestamp and skip fee minting
      // This prevents charging management fees for the period before any shares existed
      feeData.lastFeeTimestamp = block.timestamp;
      return;
    }

    // Calculate fee rate based on elapsed time
    uint256 feeRate = (s.managementFee * timeElapsed) / (365 days);
    uint256 feeShares = (currentTotalSupply * feeRate) / (10 ** s.decimals);

    if (feeShares == 0) {
      feeData.lastFeeTimestamp = block.timestamp;
      return;
    }

    address recipient = s.feeRecipient;
    if (recipient == address(0)) {
      recipient = address(this);
    }

    // Mint shares to recipient
    LibERC20._mint(recipient, feeShares);

    // Update state
    feeData.lastFeeTimestamp = block.timestamp;
    feeData.totalFeesCollected += feeShares;
  }

  /**
   * @notice Update user WAEP
   */
  function _updateUserWAEP(address user, uint256 newShares, uint256 currentSharePrice) internal {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    LibGenesisVaultStorage.UserPerformanceData storage userData = s.userPerformanceData[user];

    uint256 currentShares = s.balances[user]; // Shares before this deposit (called before _mint)

    if (currentShares == 0) {
      userData.waep = currentSharePrice;
    } else {
      userData.waep =
        (userData.waep * currentShares + currentSharePrice * newShares) /
        (currentShares + newShares);
    }

    userData.totalShares = currentShares + newShares;
    userData.lastUpdateEpoch = block.timestamp;
  }

  /**
   * @notice Calculate and charge performance fee for withdrawal
   * @dev Based on original GenesisVault.sol implementation
   * @param user The user address
   * @param withdrawShares The amount of shares being withdrawn
   * @param currentSharePrice The current share price for this epoch
   * @return feeAmount The performance fee amount in assets
   */
  function _calculateAndChargePerformanceFee(
    address user,
    uint256 withdrawShares,
    uint256 currentSharePrice
  ) internal returns (uint256 feeAmount) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    LibGenesisVaultStorage.UserPerformanceData storage userData = s.userPerformanceData[user];

    // No fee if no entry price or no profit
    if (userData.waep == 0 || currentSharePrice <= userData.waep) {
      return 0;
    }

    // Calculate profit per share
    uint256 profitPerShare = currentSharePrice - userData.waep;
    uint256 totalProfit = (profitPerShare * withdrawShares) / (10 ** s.decimals);

    // Calculate fee amount
    feeAmount = (totalProfit * s.performanceFee) / (10 ** s.decimals);

    if (feeAmount > 0) {
      // Transfer performance fee to fee recipient
      LibGenesisVault.transferFeesToRecipient(feeAmount, "performance");

      // Emit performance fee event
      emit PerformanceFeeCharged(user, feeAmount, currentSharePrice, userData.waep);
    }

    return feeAmount;
  }
}
