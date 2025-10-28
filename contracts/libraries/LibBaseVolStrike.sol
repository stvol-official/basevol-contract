// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVaultManager } from "../interfaces/IVaultManager.sol";
import { IClearingHouse } from "../interfaces/IClearingHouse.sol";
import { Round, FilledOrder, SettlementResult, WithdrawalRequest, Coupon, PriceInfo, RedeemRequest, TargetRedeemOrder, Position, PriceUpdateData, PriceData, WinPosition, CommissionTier } from "../types/Types.sol";
import { PythLazer } from "../libraries/PythLazer.sol";

library LibBaseVolStrike {
  function _getStoragePosition() internal view returns (bytes32) {
    uint256 chainId = block.chainid;
    if (chainId == 8453) {
      return keccak256("basevol.diamond.storage.secure");
    } else {
      return keccak256("basevol.diamond.storage");
    }
  }

  uint256 private constant PRICE_UNIT = 1e6;
  uint256 private constant BASE = 10000; // 100%

  event OrderSettled(
    address indexed user,
    uint256 indexed idx,
    uint256 epoch,
    uint256 prevBalance,
    uint256 newBalance,
    uint256 usedCouponAmount
  );

  struct DiamondStorage {
    IERC20 token; // Prediction token
    IPyth oracle;
    IVaultManager vaultManager;
    IClearingHouse clearingHouse;
    address adminAddress; // address of the admin
    address operatorAddress; // address of the operator
    uint256 commissionfee; // commission rate (e.g. 200 = 2%, 150 = 1.50%)
    mapping(uint256 => Round) rounds;
    mapping(uint256 => FilledOrder[]) filledOrders; // key: epoch
    uint256 lastFilledOrderId;
    uint256 lastSubmissionTime;
    uint256 lastSettledFilledOrderId; // globally
    mapping(uint256 => uint256) lastSettledFilledOrderIndex; // by round(epoch)
    mapping(uint256 => SettlementResult) settlementResults; // key: filled order idx
    mapping(uint256 => PriceInfo) priceInfos; // productId => PriceInfo
    mapping(bytes32 => uint256) priceIdToProductId; // priceId => productId
    uint256 priceIdCount;
    uint256 redeemFee; // redeem fee (e.g. 200 = 2%, 150 = 1.50%)
    address redeemVault; // vault address for redeeming
    uint256 startTimestamp; // Contract start timestamp
    uint256 intervalSeconds; // Round interval in seconds
    PythLazer pythLazer;
    // Tier-based commission system
    mapping(CommissionTier => uint256) tierCommissionRates; // Commission rate per tier
    mapping(address => CommissionTier) userTiers; // User's tier
    mapping(address => bool) userTierSet; // Whether user tier has been explicitly set

    /* IMPROTANT: you can add new variables here */
  }

  function diamondStorage() internal view returns (DiamondStorage storage ds) {
    bytes32 position = _getStoragePosition();
    assembly {
      ds.slot := position
    }
  }

  // Settlement functions
  function settleFilledOrder(
    Round storage round,
    FilledOrder storage order
  ) internal returns (uint256) {
    if (order.isSettled) return 0;

    DiamondStorage storage bvs = diamondStorage();
    uint256 strikePrice = (round.startPrice[order.productId] * order.strike) / 10000;
    bool isOverWin = strikePrice < round.endPrice[order.productId];
    bool isUnderWin = strikePrice > round.endPrice[order.productId];

    uint256 collectedFee = 0;
    WinPosition winPosition;

    if (order.overPrice + order.underPrice != 100) {
      winPosition = WinPosition.Invalid;
      if (order.overUser != order.underUser) {
        bvs.clearingHouse.releaseFromEscrow(
          address(this),
          order.overUser,
          order.epoch,
          order.idx,
          order.overPrice * order.unit * PRICE_UNIT,
          0
        );
        bvs.clearingHouse.releaseFromEscrow(
          address(this),
          order.underUser,
          order.epoch,
          order.idx,
          order.underPrice * order.unit * PRICE_UNIT,
          0
        );
        _transferRedeemedAmountsToVault(order);
        _emitSettlement(
          order.idx,
          order.epoch,
          order.underUser,
          bvs.clearingHouse.userBalances(order.underUser),
          bvs.clearingHouse.userBalances(order.underUser),
          0
        );
        _emitSettlement(
          order.idx,
          order.epoch,
          order.overUser,
          bvs.clearingHouse.userBalances(order.overUser),
          bvs.clearingHouse.userBalances(order.overUser),
          0
        );
      } else {
        bvs.clearingHouse.releaseFromEscrow(
          address(this),
          order.overUser,
          order.epoch,
          order.idx,
          (order.overPrice + order.underPrice) * order.unit * PRICE_UNIT,
          0
        );
        _transferRedeemedAmountsToVault(order);
      }
    } else if (isOverWin) {
      winPosition = WinPosition.Over;
      collectedFee += _processWin(order.overUser, order.underUser, order, winPosition);
    } else if (isUnderWin) {
      winPosition = WinPosition.Under;
      collectedFee += _processWin(order.underUser, order.overUser, order, winPosition);
    } else {
      // Tie case
      uint256 overUserBalance = bvs.clearingHouse.userBalances(order.overUser);
      uint256 underUserBalance = bvs.clearingHouse.userBalances(order.underUser);
      winPosition = WinPosition.Tie;
      bvs.clearingHouse.releaseFromEscrow(
        address(this),
        order.overUser,
        order.epoch,
        order.idx,
        order.overPrice * order.unit * PRICE_UNIT,
        0
      );
      bvs.clearingHouse.releaseFromEscrow(
        address(this),
        order.underUser,
        order.epoch,
        order.idx,
        order.underPrice * order.unit * PRICE_UNIT,
        0
      );
      _emitSettlement(
        order.idx,
        order.epoch,
        order.overUser,
        overUserBalance,
        bvs.clearingHouse.userBalances(order.overUser),
        0
      );
      _emitSettlement(
        order.idx,
        order.epoch,
        order.underUser,
        underUserBalance,
        bvs.clearingHouse.userBalances(order.underUser),
        0
      );
      // Use tier-based commission fee (use overUser's tier for Tie case)
      uint256 commissionRate = getCommissionFeeForUser(order.overUser);

      bvs.settlementResults[order.idx] = SettlementResult({
        idx: order.idx,
        winPosition: WinPosition.Tie,
        winAmount: 0,
        feeRate: commissionRate,
        fee: 0
      });
    }

    order.isSettled = true;
    return collectedFee;
  }

  function _processWin(
    address winner,
    address loser,
    FilledOrder storage order,
    WinPosition winPosition
  ) private returns (uint256) {
    DiamondStorage storage bvs = diamondStorage();

    uint256 winnerAmount = order.overUser == winner
      ? order.overPrice * order.unit * PRICE_UNIT
      : order.underPrice * order.unit * PRICE_UNIT;

    uint256 loserAmount = order.overUser == loser
      ? order.overPrice * order.unit * PRICE_UNIT
      : order.underPrice * order.unit * PRICE_UNIT;

    // Use tier-based commission fee
    uint256 commissionRate = getCommissionFeeForUser(loser);
    uint256 fee = (loserAmount * commissionRate) / BASE;

    _processWinSettlement(winner, loser, order, winnerAmount, loserAmount, fee, winPosition, bvs);

    bvs.settlementResults[order.idx] = SettlementResult({
      idx: order.idx,
      winPosition: winPosition,
      winAmount: loserAmount,
      feeRate: commissionRate,
      fee: fee
    });

    return fee;
  }

  function _processWinSettlement(
    address winner,
    address loser,
    FilledOrder storage order,
    uint256 winnerAmount,
    uint256 loserAmount,
    uint256 fee,
    WinPosition winPosition,
    DiamondStorage storage bvs
  ) private {
    // Calculate redeem ratio
    uint256 winnerRedeemed = (winPosition == WinPosition.Over)
      ? order.overRedeemed
      : order.underRedeemed;
    uint256 redeemRatio = winnerRedeemed > 0 ? (winnerRedeemed * PRICE_UNIT) / order.unit : 0;

    // Process escrow settlements
    _processEscrowSettlements(winner, loser, order, loserAmount, fee, redeemRatio, bvs);

    // Release winner's original escrow and handle redeemed portion
    _processWinnerSettlement(winner, order, winnerAmount, redeemRatio, bvs);

    // Emit settlement events
    _emitSettlementEvents(winner, loser, order, winnerAmount, loserAmount, fee, redeemRatio, bvs);
  }

  function _processEscrowSettlements(
    address winner,
    address loser,
    FilledOrder storage order,
    uint256 loserAmount,
    uint256 fee,
    uint256 redeemRatio,
    DiamondStorage storage bvs
  ) private {
    // Split loser's amount (winning profit) based on redeem ratio
    uint256 vaultWinAmount = (loserAmount * redeemRatio) / PRICE_UNIT;
    uint256 userWinAmount = loserAmount - vaultWinAmount;
    uint256 vaultFee = (fee * redeemRatio) / PRICE_UNIT;
    uint256 userFee = fee - vaultFee;

    // Transfer loser's escrow to redeemVault and winner based on redeem ratio
    if (vaultWinAmount > 0) {
      bvs.clearingHouse.settleEscrowWithFee(
        address(this),
        loser,
        bvs.redeemVault,
        order.epoch,
        vaultWinAmount,
        order.idx,
        vaultFee
      );
    }

    if (userWinAmount > 0) {
      bvs.clearingHouse.settleEscrowWithFee(
        address(this),
        loser,
        winner,
        order.epoch,
        userWinAmount,
        order.idx,
        userFee
      );
    }
  }

  function _processWinnerSettlement(
    address winner,
    FilledOrder storage order,
    uint256 winnerAmount,
    uint256 redeemRatio,
    DiamondStorage storage bvs
  ) private {
    // Release winner's original escrow to winner first
    bvs.clearingHouse.releaseFromEscrow(
      address(this),
      winner,
      order.epoch,
      order.idx,
      winnerAmount,
      0
    );

    // Then transfer redeem portion from winner to redeemVault
    if (redeemRatio > 0) {
      uint256 redeemAmount = (winnerAmount * redeemRatio) / PRICE_UNIT;
      if (redeemAmount > 0) {
        bvs.clearingHouse.subtractUserBalance(winner, redeemAmount);
        bvs.clearingHouse.addUserBalance(bvs.redeemVault, redeemAmount);
      }
    }
  }

  function _emitSettlementEvents(
    address winner,
    address loser,
    FilledOrder storage order,
    uint256 winnerAmount,
    uint256 loserAmount,
    uint256 fee,
    uint256 redeemRatio,
    DiamondStorage storage bvs
  ) private {
    // Emit loser settlement event
    uint256 usedCoupon = bvs.clearingHouse.escrowCoupons(
      address(this),
      order.epoch,
      loser,
      order.idx
    );
    uint256 loserBalance = bvs.clearingHouse.userBalances(loser);
    _emitSettlement(
      order.idx,
      order.epoch,
      loser,
      loserBalance + loserAmount,
      loserBalance,
      usedCoupon
    );

    // Emit winner settlement event
    uint256 vaultWinnerAmount = redeemRatio > 0 ? (winnerAmount * redeemRatio) / PRICE_UNIT : 0;
    uint256 vaultWinAmount = (loserAmount * redeemRatio) / PRICE_UNIT;
    uint256 userWinAmount = loserAmount - vaultWinAmount;
    uint256 userFee = fee - ((fee * redeemRatio) / PRICE_UNIT);
    uint256 winnerTotalReceived = userWinAmount - userFee + (winnerAmount - vaultWinnerAmount);
    uint256 winnerBalance = bvs.clearingHouse.userBalances(winner);
    uint256 winnerPrevBalance = winnerBalance - winnerTotalReceived;
    _emitSettlement(order.idx, order.epoch, winner, winnerPrevBalance, winnerBalance, 0);

    // Emit vault settlement event if applicable
    if (vaultWinAmount > 0 || vaultWinnerAmount > 0) {
      uint256 vaultFee = (fee * redeemRatio) / PRICE_UNIT;
      uint256 vaultTotalReceived = vaultWinAmount - vaultFee + vaultWinnerAmount;
      uint256 vaultBalance = bvs.clearingHouse.userBalances(bvs.redeemVault);
      _emitSettlement(
        order.idx,
        order.epoch,
        bvs.redeemVault,
        vaultBalance - vaultTotalReceived,
        vaultBalance,
        0
      );
    }
  }

  function _transferRedeemedAmountsToVault(FilledOrder storage order) private {
    DiamondStorage storage bvs = diamondStorage();
    if (order.underRedeemed > 0) {
      uint256 redeemedAmount = order.underPrice * order.underRedeemed * PRICE_UNIT;
      bvs.clearingHouse.subtractUserBalance(order.underUser, redeemedAmount);
      bvs.clearingHouse.addUserBalance(bvs.redeemVault, redeemedAmount);
    }
    if (order.overRedeemed > 0) {
      uint256 redeemedAmount = order.overPrice * order.overRedeemed * PRICE_UNIT;
      bvs.clearingHouse.subtractUserBalance(order.overUser, redeemedAmount);
      bvs.clearingHouse.addUserBalance(bvs.redeemVault, redeemedAmount);
    }
  }

  function _emitSettlement(
    uint256 idx,
    uint256 epoch,
    address user,
    uint256 prevBalance,
    uint256 newBalance,
    uint256 usedCouponAmount
  ) private {
    emit OrderSettled(user, idx, epoch, prevBalance, newBalance, usedCouponAmount);
  }

  // Import all necessary errors from BaseVolErrors
  error InvalidAddress();
  error InvalidCommissionFee();
  error InvalidInitDate();
  error InvalidRound();
  error InvalidRoundPrice();
  error InvalidId();
  error AlreadySettled();
  error InvalidAmount();
  error InvalidStrike();
  error InvalidPriceId();
  error InvalidProductId();
  error InvalidSymbol();
  error PriceIdAlreadyExists();
  error ProductIdAlreadyExists();
  error InvalidTokenAddress();
  error InvalidEpoch();
  error EpochHasNotStartedYet();
  error InsufficientVerificationFee();
  error InvalidChannel();

  // Specific errors for redeemPairs debugging
  error InvalidOverUnitsSum();
  error InvalidUnderUnitsSum();
  error InsufficientOverRedeemable();
  error InsufficientUnderRedeemable();
  error CommissionExceedsRedemption();

  // Tier-based commission helper functions
  function getCommissionTier(address user) internal view returns (CommissionTier) {
    DiamondStorage storage bvs = diamondStorage();

    if (bvs.userTierSet[user]) {
      return bvs.userTiers[user];
    }

    // Always use NORMAL as default
    return CommissionTier.NORMAL;
  }

  function getCommissionFeeForUser(address user) public view returns (uint256) {
    DiamondStorage storage bvs = diamondStorage();
    CommissionTier tier = getCommissionTier(user);

    // If tier rate is not set, fallback to legacy commissionfee
    uint256 tierRate = bvs.tierCommissionRates[tier];
    return tierRate > 0 ? tierRate : bvs.commissionfee;
  }

  function setCommissionTier(address user, CommissionTier tier) internal {
    DiamondStorage storage bvs = diamondStorage();
    if (user == address(0)) revert InvalidAddress();

    // NORMAL tier should not be explicitly set - it's the default
    if (tier == CommissionTier.NORMAL) {
      // Just remove any existing tier setting to revert to default
      bvs.userTierSet[user] = false;
      return;
    }

    bvs.userTiers[user] = tier;
    bvs.userTierSet[user] = true;
  }

  function removeCommissionTier(address user) internal {
    DiamondStorage storage bvs = diamondStorage();
    bvs.userTierSet[user] = false;
  }

  function setTierCommissionRate(CommissionTier tier, uint256 rate) internal {
    DiamondStorage storage bvs = diamondStorage();
    bvs.tierCommissionRates[tier] = rate;
  }

  // Access control modifiers
  modifier onlyAdmin() {
    require(msg.sender == diamondStorage().adminAddress, "Only admin");
    _;
  }

  modifier onlyOperator() {
    require(msg.sender == diamondStorage().operatorAddress, "Only operator");
    _;
  }

  // onlyOwner modifier will be implemented in individual facets using LibDiamond.enforceIsContractOwner()
}
