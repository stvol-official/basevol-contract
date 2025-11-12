// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibBaseVolStrike } from "../libraries/LibBaseVolStrike.sol";
import { LibDiamond } from "../../diamond-common/libraries/LibDiamond.sol";
import { FilledOrder, Round, SettlementResult, WinPosition } from "../../types/Types.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract OrderProcessingFacet is ReentrancyGuard {
  using LibBaseVolStrike for LibBaseVolStrike.DiamondStorage;

  uint256 private constant PRICE_UNIT = 1e6;
  uint256 private constant BASE = 10000; // 100%

  event RoundBatchSettled(
    uint256 indexed epoch,
    uint256 settledCount,
    uint256 remainingCount,
    uint256 collectedFee
  );

  event RoundFullySettled(uint256 indexed epoch, uint256 totalOrders, uint256 totalFee);

  modifier onlyOperator() {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    require(msg.sender == bvs.operatorAddress, "Only operator");
    _;
  }

  function submitFilledOrders(
    FilledOrder[] calldata transactions
  ) external nonReentrant onlyOperator {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();

    // Check for empty array
    if (transactions.length == 0) revert LibBaseVolStrike.InvalidAmount();

    uint256 lastId = bvs.lastFilledOrderId;

    for (uint i = 0; i < transactions.length; i++) {
      FilledOrder calldata order = transactions[i];

      // Verify each transaction has an ID greater than the previous one
      // This prevents duplicate orders and ensures monotonically increasing IDs
      if (order.idx <= lastId) revert LibBaseVolStrike.InvalidId();

      // Calculate required amounts
      uint256 overAmount = order.overPrice * order.unit * PRICE_UNIT;
      uint256 underAmount = order.underPrice * order.unit * PRICE_UNIT;

      // Lock in escrow for both parties
      bvs.clearingHouse.lockInEscrow(
        address(this),
        order.overUser,
        overAmount,
        order.epoch,
        order.idx,
        true
      );
      bvs.clearingHouse.lockInEscrow(
        address(this),
        order.underUser,
        underAmount,
        order.epoch,
        order.idx,
        true
      );

      FilledOrder[] storage orders = bvs.filledOrders[order.epoch];
      orders.push(order);

      Round storage round = bvs.rounds[order.epoch];
      if (round.isSettled) {
        _settleFilledOrder(round, orders[orders.length - 1]);
      }

      // Update lastId for next iteration
      lastId = order.idx;
    }
    bvs.lastFilledOrderId = transactions[transactions.length - 1].idx;
    bvs.lastSubmissionTime = block.timestamp;
  }

  function settleFilledOrders(uint256 epoch, uint256 size) public onlyOperator returns (uint256) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    Round storage round = bvs.rounds[epoch];

    if (round.epoch == 0 || round.startTimestamp == 0 || round.endTimestamp == 0)
      revert LibBaseVolStrike.InvalidRound();
    if (round.startPrice[0] == 0 || round.endPrice[0] == 0)
      revert LibBaseVolStrike.InvalidRoundPrice();

    FilledOrder[] storage orders = bvs.filledOrders[epoch];

    // Get starting index from storage
    uint256 startIndex = bvs.settledOrderIndex[epoch];

    // Check if already fully settled
    if (startIndex >= orders.length) {
      return 0; // No remaining orders
    }

    // Calculate end index
    uint256 endIndex = startIndex + size;
    if (endIndex > orders.length) {
      endIndex = orders.length;
    }

    uint256 collectedFee = 0;
    uint256 settledCount = 0;

    // Settle orders from startIndex to endIndex
    for (uint256 i = startIndex; i < endIndex; i++) {
      FilledOrder storage order = orders[i];

      // Skip already settled orders
      if (!order.isSettled) {
        uint256 fee = _settleFilledOrder(round, order);
        collectedFee += fee;
        settledCount++;
      }
    }

    // Update progress in storage
    bvs.settledOrderIndex[epoch] = endIndex;

    // Emit appropriate event
    if (endIndex >= orders.length) {
      bvs.isFullySettled[epoch] = true;
      emit RoundFullySettled(epoch, orders.length, collectedFee);
    } else {
      emit RoundBatchSettled(epoch, settledCount, orders.length - endIndex, collectedFee);
    }

    // Return remaining orders count
    return orders.length - endIndex;
  }

  function countUnsettledFilledOrders(uint256 epoch) external view returns (uint256) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    FilledOrder[] storage orders = bvs.filledOrders[epoch];
    uint256 unsettledCount = 0;
    for (uint i = 0; i < orders.length; i++) {
      if (!orders[i].isSettled) {
        unsettledCount++;
      }
    }
    return unsettledCount;
  }

  function getSettlementProgress(
    uint256 epoch
  )
    external
    view
    returns (
      uint256 totalOrders,
      uint256 settledIndex,
      uint256 remainingOrders,
      bool isFullySettled
    )
  {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    FilledOrder[] storage orders = bvs.filledOrders[epoch];

    totalOrders = orders.length;
    settledIndex = bvs.settledOrderIndex[epoch];
    remainingOrders = totalOrders > settledIndex ? totalOrders - settledIndex : 0;
    isFullySettled = bvs.isFullySettled[epoch];
  }

  function fillSettlementResult(uint256[] calldata epochList) external {
    // temporary function to fill settlement results
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    for (uint a = 0; a < epochList.length; a++) {
      uint256 epoch = epochList[a];
      FilledOrder[] storage orders = bvs.filledOrders[epoch];
      Round storage round = bvs.rounds[epoch];
      for (uint i = 0; i < orders.length; i++) {
        FilledOrder storage order = orders[i];
        _fillSettlementResult(round, order);
      }
    }
  }

  // Internal functions
  function _settleFilledOrder(
    Round storage round,
    FilledOrder storage order
  ) internal returns (uint256) {
    return LibBaseVolStrike.settleFilledOrder(round, order);
  }

  function _fillSettlementResult(Round storage round, FilledOrder storage order) internal {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();

    if (round.startPrice[order.productId] == 0 || round.endPrice[order.productId] == 0) return;

    uint256 strikePrice = (round.startPrice[order.productId] * order.strike) / 10000;

    bool isOverWin = strikePrice < round.endPrice[order.productId];
    bool isUnderWin = strikePrice > round.endPrice[order.productId];

    // Get commission fee for this round (fallback to global if not set)
    uint256 roundCommissionFee = round.commissionFee > 0 ? round.commissionFee : bvs.commissionfee;

    if (order.overPrice + order.underPrice != 100) {
      bvs.settlementResults[order.idx] = SettlementResult({
        idx: order.idx,
        winPosition: WinPosition.Invalid,
        winAmount: 0,
        feeRate: roundCommissionFee,
        fee: 0
      });
    } else if (order.overUser == order.underUser) {
      uint256 loosePositionAmount = (
        isOverWin
          ? order.underPrice
          : isUnderWin
            ? order.overPrice
            : 0
      ) *
        order.unit *
        PRICE_UNIT;
      uint256 fee = (loosePositionAmount * roundCommissionFee) / BASE;

      bvs.settlementResults[order.idx] = SettlementResult({
        idx: order.idx,
        winPosition: isOverWin
          ? WinPosition.Over
          : isUnderWin
            ? WinPosition.Under
            : WinPosition.Tie,
        winAmount: loosePositionAmount,
        feeRate: roundCommissionFee,
        fee: fee
      });
    } else if (isUnderWin) {
      uint256 amount = order.overPrice * order.unit * PRICE_UNIT;
      uint256 fee = (amount * roundCommissionFee) / BASE;

      bvs.settlementResults[order.idx] = SettlementResult({
        idx: order.idx,
        winPosition: WinPosition.Under,
        winAmount: amount,
        feeRate: roundCommissionFee,
        fee: fee
      });
    } else if (isOverWin) {
      uint256 amount = order.underPrice * order.unit * PRICE_UNIT;
      uint256 fee = (amount * roundCommissionFee) / BASE;

      bvs.settlementResults[order.idx] = SettlementResult({
        idx: order.idx,
        winPosition: WinPosition.Over,
        winAmount: amount,
        feeRate: roundCommissionFee,
        fee: fee
      });
    } else {
      // no one wins
      bvs.settlementResults[order.idx] = SettlementResult({
        idx: order.idx,
        winPosition: WinPosition.Tie,
        winAmount: 0,
        feeRate: roundCommissionFee,
        fee: 0
      });
    }
  }

  event OrderSettled(
    address indexed user,
    uint256 indexed idx,
    uint256 epoch,
    uint256 prevBalance,
    uint256 newBalance,
    uint256 usedCouponAmount
  );

  function _transferRedeemedAmountsToVault(FilledOrder storage order) internal {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
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
}
