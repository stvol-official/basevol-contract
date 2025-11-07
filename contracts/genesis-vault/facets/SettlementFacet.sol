// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibGenesisVaultStorage } from "../libraries/LibGenesisVaultStorage.sol";
import { LibGenesisVault } from "../libraries/LibGenesisVault.sol";
import { LibERC20 } from "../libraries/LibERC20.sol";
import { IGenesisStrategy } from "../../core/vault/interfaces/IGenesisStrategy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title SettlementFacet
 * @notice Handles epoch settlement logic for GenesisVault Diamond
 * @dev Called by keepers when BaseVol rounds settle
 */
contract SettlementFacet {
  using Math for uint256;

  uint256 internal constant FLOAT_PRECISION = 1e18;
  uint256 internal constant SETTLEMENT_BATCH_SIZE = 50;
  uint256 internal constant MINIMUM_FIRST_DEPOSIT = 1000e6; // 1000 USDC

  // ============ Events ============
  event RoundSettled(uint256 indexed epoch, uint256 sharePrice);
  event RoundSettlementProcessed(
    uint256 indexed epoch,
    uint256 requiredRedeemAssets,
    uint256 availableAssets
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
  event SettlementBalanceWarning(
    uint256 indexed epoch,
    uint256 requiredAssets,
    uint256 availableAssets,
    uint256 deficit
  );
  event BatchSettlementProcessed(
    uint256 indexed epoch,
    uint256 depositProcessed,
    uint256 depositRemaining,
    uint256 redeemProcessed,
    uint256 redeemRemaining
  );
  event EpochSettlementCompleted(uint256 indexed epoch);
  event DepositRefunded(address indexed user, uint256 indexed epoch, uint256 assets, string reason);

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
   * @dev Processes users in batches to avoid gas limit issues
   * @param epoch The epoch that was settled
   */
  function onRoundSettled(uint256 epoch) external onlyKeeper {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];

    // First call: Initialize settlement
    if (!roundData.isSettled) {
      // Calculate share price based on vault's current state
      uint256 sharePrice = _calculateCurrentSharePrice();

      roundData.sharePrice = sharePrice;
      roundData.isSettled = true;
      roundData.settlementTimestamp = block.timestamp;
      emit RoundSettled(epoch, sharePrice);

      // CRITICAL: Process management fee BEFORE minting new shares
      // This ensures management fee is only charged on shares that existed during the period
      _mintManagementFeeShares();

      // Withdraw all strategy assets for settlement
      _withdrawStrategyAssetsForSettlement();
    } else {
      // Already settled, check if this is a legacy epoch (upgrade scenario)
      if (roundData.processedDepositUserCount == 0 && roundData.processedRedeemUserCount == 0) {
        uint256 totalDepositUsers = s.epochDepositUsers[epoch].length;
        uint256 totalRedeemUsers = s.epochRedeemUsers[epoch].length;

        // If there are users but counts are 0, this is a legacy epoch already processed
        // Mark as complete to prevent reprocessing
        if (totalDepositUsers > 0 || totalRedeemUsers > 0) {
          roundData.processedDepositUserCount = totalDepositUsers;
          roundData.processedRedeemUserCount = totalRedeemUsers;
          emit EpochSettlementCompleted(epoch);
          return;
        }
      }
    }

    // Process batch of users
    (uint256 depositProcessed, uint256 depositRemaining) = _autoProcessEpochDeposits(epoch);
    (uint256 redeemProcessed, uint256 redeemRemaining) = _autoProcessEpochRedeems(epoch);

    emit BatchSettlementProcessed(
      epoch,
      depositProcessed,
      depositRemaining,
      redeemProcessed,
      redeemRemaining
    );

    // All users processed
    if (depositRemaining == 0 && redeemRemaining == 0) {
      // Signal strategy for idle asset utilization
      _notifyStrategyForUtilization();
      emit EpochSettlementCompleted(epoch);
    }
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
   * @notice Withdraw all strategy assets (BaseVol, Morpho, and idle) for settlement accounting
   */
  function _withdrawStrategyAssetsForSettlement() internal {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    address strategyAddr = s.strategy;

    if (strategyAddr == address(0)) {
      return;
    }

    try IGenesisStrategy(strategyAddr).withdrawAllStrategyAssetsForSettlement() {
      emit StrategyLiquidityRequested(0); // 0 indicates full strategy assets withdrawal for settlement
    } catch Error(string memory reason) {
      // emit StrategyLiquidityRequestFailed(
      //   0,
      //   string(abi.encodePacked("Strategy settlement withdrawal failed: ", reason))
      // );

      revert(string(abi.encodePacked("StrategyLiquidityRequestFailed: ", reason)));
    } catch Panic(uint256 errorCode) {
      // emit StrategyLiquidityRequestFailed(
      //   0,
      //   string(
      //     abi.encodePacked(
      //       "Strategy settlement withdrawal failed: Panic error code ",
      //       _uint2str(errorCode)
      //     )
      //   )
      // );
      revert(
        string(
          abi.encodePacked(
            "StrategyLiquidityRequestFailed: Panic error code ",
            _uint2str(errorCode)
          )
        )
      );
    } catch (bytes memory lowLevelData) {
      // Log low-level error data for debugging
      string memory errorMsg = "Strategy settlement withdrawal failed: Unknown error";
      if (lowLevelData.length > 0) {
        // Try to decode as string
        if (lowLevelData.length >= 68) {
          // Standard Error(string) selector is 0x08c379a0
          bytes4 errorSelector;
          assembly {
            errorSelector := mload(add(lowLevelData, 0x20))
          }
          if (errorSelector == 0x08c379a0) {
            // Decode the error string
            assembly {
              lowLevelData := add(lowLevelData, 0x04)
            }
            errorMsg = string(
              abi.encodePacked(
                "Strategy settlement withdrawal failed: ",
                abi.decode(lowLevelData, (string))
              )
            );
          } else {
            errorMsg = string(
              abi.encodePacked(
                "Strategy settlement withdrawal failed: Raw error (bytes length: ",
                _uint2str(lowLevelData.length),
                ")"
              )
            );
          }
        } else {
          errorMsg = string(
            abi.encodePacked(
              "Strategy settlement withdrawal failed: Raw error (bytes length: ",
              _uint2str(lowLevelData.length),
              ")"
            )
          );
        }
      }
      // emit StrategyLiquidityRequestFailed(0, errorMsg);
      revert(string(abi.encodePacked("StrategyLiquidityRequestFailed: ", errorMsg)));
    }
  }

  /**
   * @notice Convert uint256 to string
   * @dev Helper function for error logging
   */
  function _uint2str(uint256 _i) internal pure returns (string memory) {
    if (_i == 0) {
      return "0";
    }
    uint256 j = _i;
    uint256 len;
    while (j != 0) {
      len++;
      j /= 10;
    }
    bytes memory bstr = new bytes(len);
    uint256 k = len;
    while (_i != 0) {
      k = k - 1;
      uint8 temp = (48 + uint8(_i - (_i / 10) * 10));
      bytes1 b1 = bytes1(temp);
      bstr[k] = b1;
      _i /= 10;
    }
    return string(bstr);
  }

  /**
   * @notice Auto-process deposit requests for an epoch in batches
   * @param epoch The epoch to process
   * @return processed Number of users processed in this batch
   * @return remaining Number of users remaining to process
   */
  function _autoProcessEpochDeposits(
    uint256 epoch
  ) internal returns (uint256 processed, uint256 remaining) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];

    address[] memory users = s.epochDepositUsers[epoch];
    uint256 startIndex = roundData.processedDepositUserCount;
    uint256 endIndex = Math.min(startIndex + SETTLEMENT_BATCH_SIZE, users.length);

    for (uint256 i = startIndex; i < endIndex; i++) {
      _autoProcessUserDeposit(users[i], epoch);
    }

    processed = endIndex - startIndex;
    roundData.processedDepositUserCount = endIndex;
    remaining = users.length - endIndex;

    return (processed, remaining);
  }

  /**
   * @notice Auto-process redeem requests for an epoch in batches
   * @param epoch The epoch to process
   * @return processed Number of users processed in this batch
   * @return remaining Number of users remaining to process
   */
  function _autoProcessEpochRedeems(
    uint256 epoch
  ) internal returns (uint256 processed, uint256 remaining) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];

    address[] memory users = s.epochRedeemUsers[epoch];
    uint256 startIndex = roundData.processedRedeemUserCount;
    uint256 endIndex = Math.min(startIndex + SETTLEMENT_BATCH_SIZE, users.length);

    for (uint256 i = startIndex; i < endIndex; i++) {
      _autoProcessUserRedeem(users[i], epoch);
    }

    processed = endIndex - startIndex;
    roundData.processedRedeemUserCount = endIndex;
    remaining = users.length - endIndex;

    return (processed, remaining);
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

    // SECURITY: Minimum first deposit check (donation attack prevention)
    if (s.totalSupply == 0 && claimableAssets < MINIMUM_FIRST_DEPOSIT) {
      revert("SettlementFacet: First deposit too small");
    }

    // Calculate shares to mint using epoch-specific share price
    uint256 sharesToMint = (claimableAssets * (10 ** s.decimals)) / roundData.sharePrice;

    // SECURITY: Zero share prevention (donation attack prevention)
    // Refund instead of revert to prevent griefing attack
    if (sharesToMint == 0) {
      // Refund the deposited assets to the user
      IERC20(s.asset).transfer(user, claimableAssets);

      // Mark as fully claimed (refunded) to remove from pending
      roundData.claimedDepositAssets += claimableAssets;
      s.userEpochClaimedDepositAssets[user][epoch] += claimableAssets;

      // Emit refund event
      emit DepositRefunded(user, epoch, claimableAssets, "Would receive 0 shares");
      return;
    }

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

    // Check vault balance before any transfers
    uint256 totalRequired = exitCostAmount + performanceFeeAmount + netAssets;
    uint256 currentBalance = s.asset.balanceOf(address(this));
    require(
      currentBalance >= totalRequired,
      "SettlementFacet: Insufficient vault balance for redeem"
    );

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
    // FIX: Use 1e18 instead of (10 ** s.decimals) to match VaultCoreFacet.sol:779
    // performanceFee is stored in 18 decimals (e.g., 0.2 * 1e18 = 20%)
    feeAmount = (totalProfit * s.performanceFee) / FLOAT_PRECISION;

    // Safety check: fee should not exceed total profit
    if (feeAmount > totalProfit) {
      feeAmount = totalProfit;
    }

    if (feeAmount > 0) {
      // Transfer performance fee to fee recipient
      LibGenesisVault.transferFeesToRecipient(feeAmount, "performance");

      // Emit performance fee event
      emit PerformanceFeeCharged(user, feeAmount, currentSharePrice, userData.waep);
    }

    return feeAmount;
  }

  // ============ View Functions ============

  /**
   * @notice Get remaining settlement count for an epoch
   * @param epoch The epoch to check
   * @return remainingDeposits Number of deposit users remaining to process
   * @return remainingRedeems Number of redeem users remaining to process
   * @return isComplete Whether settlement is complete
   */
  function getRemainingSettlementCount(
    uint256 epoch
  ) external view returns (uint256 remainingDeposits, uint256 remainingRedeems, bool isComplete) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];

    if (!roundData.isSettled) {
      return (0, 0, false);
    }

    uint256 totalDepositUsers = s.epochDepositUsers[epoch].length;
    uint256 totalRedeemUsers = s.epochRedeemUsers[epoch].length;

    remainingDeposits = totalDepositUsers > roundData.processedDepositUserCount
      ? totalDepositUsers - roundData.processedDepositUserCount
      : 0;

    remainingRedeems = totalRedeemUsers > roundData.processedRedeemUserCount
      ? totalRedeemUsers - roundData.processedRedeemUserCount
      : 0;

    isComplete = (remainingDeposits == 0 && remainingRedeems == 0);

    return (remainingDeposits, remainingRedeems, isComplete);
  }

  /**
   * @notice Get settlement progress for an epoch
   * @param epoch The epoch to check
   * @return totalDeposits Total number of deposit users
   * @return processedDeposits Number of deposit users processed
   * @return totalRedeems Total number of redeem users
   * @return processedRedeems Number of redeem users processed
   */
  function getSettlementProgress(
    uint256 epoch
  )
    external
    view
    returns (
      uint256 totalDeposits,
      uint256 processedDeposits,
      uint256 totalRedeems,
      uint256 processedRedeems
    )
  {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];

    totalDeposits = s.epochDepositUsers[epoch].length;
    processedDeposits = roundData.processedDepositUserCount;
    totalRedeems = s.epochRedeemUsers[epoch].length;
    processedRedeems = roundData.processedRedeemUserCount;

    return (totalDeposits, processedDeposits, totalRedeems, processedRedeems);
  }
}
