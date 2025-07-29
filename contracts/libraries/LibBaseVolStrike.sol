// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVaultManager } from "../interfaces/IVaultManager.sol";
import { IClearingHouse } from "../interfaces/IClearingHouse.sol";
import { Round, FilledOrder, SettlementResult, WithdrawalRequest, Coupon, PriceInfo, RedeemRequest, TargetRedeemOrder, Position, PriceUpdateData, ManualPriceData, WinPosition } from "../types/Types.sol";

library LibBaseVolStrike {
  bytes32 constant DIAMOND_STORAGE_POSITION = keccak256("basevol.diamond.storage");

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
    /* IMPROTANT: you can add new variables here */
  }

  function diamondStorage() internal pure returns (DiamondStorage storage ds) {
    bytes32 position = DIAMOND_STORAGE_POSITION;
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
      bvs.settlementResults[order.idx] = SettlementResult({
        idx: order.idx,
        winPosition: WinPosition.Tie,
        winAmount: 0,
        feeRate: bvs.commissionfee,
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
    uint256 fee = (loserAmount * bvs.commissionfee) / BASE;

    // Calculate redeem ratio
    uint256 winnerRedeemed = (winPosition == WinPosition.Over)
      ? order.overRedeemed
      : order.underRedeemed;
    uint256 redeemRatio = winnerRedeemed > 0 ? (winnerRedeemed * PRICE_UNIT) / order.unit : 0;

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

    // Get coupon information for events
    uint256 usedCoupon = bvs.clearingHouse.escrowCoupons(
      address(this),
      order.epoch,
      loser,
      order.idx
    );

    // Emit settlement events for loser
    _emitSettlement(
      order.idx,
      order.epoch,
      loser,
      bvs.clearingHouse.userBalances(loser) + loserAmount,
      bvs.clearingHouse.userBalances(loser),
      usedCoupon
    );

    // Calculate final amounts for events
    uint256 vaultWinnerAmount = redeemRatio > 0 ? (winnerAmount * redeemRatio) / PRICE_UNIT : 0;
    uint256 winnerTotalReceived = userWinAmount + (winnerAmount - vaultWinnerAmount);

    // Emit settlement event for winner
    _emitSettlement(
      order.idx,
      order.epoch,
      winner,
      bvs.clearingHouse.userBalances(winner) - winnerTotalReceived,
      bvs.clearingHouse.userBalances(winner),
      0
    );

    // Emit settlement event for redeemVault if applicable
    if (vaultWinAmount > 0 || vaultWinnerAmount > 0) {
      uint256 vaultTotalReceived = vaultWinAmount + vaultWinnerAmount;
      _emitSettlement(
        order.idx,
        order.epoch,
        bvs.redeemVault,
        bvs.clearingHouse.userBalances(bvs.redeemVault) - vaultTotalReceived,
        bvs.clearingHouse.userBalances(bvs.redeemVault),
        0
      );
    }

    bvs.settlementResults[order.idx] = SettlementResult({
      idx: order.idx,
      winPosition: winPosition,
      winAmount: loserAmount,
      feeRate: bvs.commissionfee,
      fee: fee
    });
    return fee;
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

  // Specific errors for redeemPairs debugging
  error InvalidOverUnitsSum();
  error InvalidUnderUnitsSum();
  error InsufficientOverRedeemable();
  error InsufficientUnderRedeemable();
  error CommissionExceedsRedemption();

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
