// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IClearingHouse } from "../interfaces/IClearingHouse.sol";
import { FilledOrder, Position, RedeemRequest, TargetRedeemOrder } from "../types/Types.sol";

library RedeemLib {
  uint256 private constant PRICE_UNIT = 1e6;
  uint256 private constant BASE = 10000; // 100%

  error InvalidId();
  error AlreadySettled();
  error InvalidAddress();
  error InvalidAmount();

  function validateRedeemRequest(
    FilledOrder storage order,
    RedeemRequest calldata request
  ) internal view {
    if (order.idx != request.idx) revert InvalidId();
    if (order.isSettled) revert AlreadySettled();

    if (request.position == Position.Over) {
      if (order.overUser != request.user) revert InvalidAddress();
      if (request.unit > order.unit - order.overRedeemed) revert InvalidAmount();
    } else {
      if (order.underUser != request.user) revert InvalidAddress();
      if (request.unit > order.unit - order.underRedeemed) revert InvalidAmount();
    }
  }

  function validateTargetRedeemOrders(
    mapping(uint256 => FilledOrder[]) storage filledOrders,
    RedeemRequest calldata request
  ) internal view returns (uint256 totalRedeemed) {
    totalRedeemed = 0;

    for (uint i = 0; i < request.targetRedeemOrders.length; i++) {
      totalRedeemed += request.targetRedeemOrders[i].unit;
      TargetRedeemOrder calldata targetRedeemOrder = request.targetRedeemOrders[i];
      FilledOrder storage targetOrder = filledOrders[request.epoch][targetRedeemOrder.idx];

      if (targetOrder.idx != targetRedeemOrder.idx) revert InvalidId();
      if (targetOrder.isSettled) revert AlreadySettled();

      if (request.position == Position.Over) {
        if (targetOrder.underUser != request.user) revert InvalidAddress();
        if (targetRedeemOrder.unit > targetOrder.unit - targetOrder.underRedeemed)
          revert InvalidAmount();
      } else {
        if (targetOrder.overUser != request.user) revert InvalidAddress();
        if (targetRedeemOrder.unit > targetOrder.unit - targetOrder.overRedeemed)
          revert InvalidAmount();
      }
    }

    if (totalRedeemed != request.unit) revert InvalidAmount();
  }

  function updateOrderRedemptions(
    FilledOrder storage order,
    RedeemRequest calldata request
  ) internal returns (uint256 paidAmount) {
    uint256 orderPrice = request.position == Position.Over ? order.overPrice : order.underPrice;

    if (request.position == Position.Over) {
      order.overRedeemed += request.unit;
      paidAmount = orderPrice * request.unit * PRICE_UNIT;
    } else {
      order.underRedeemed += request.unit;
      paidAmount = orderPrice * request.unit * PRICE_UNIT;
    }
  }

  function updateTargetOrderRedemptions(
    mapping(uint256 => FilledOrder[]) storage filledOrders,
    RedeemRequest calldata request,
    uint256 basePaidAmount
  ) internal returns (uint256 totalPaidAmount) {
    totalPaidAmount = basePaidAmount;

    for (uint i = 0; i < request.targetRedeemOrders.length; i++) {
      TargetRedeemOrder calldata targetRedeemOrder = request.targetRedeemOrders[i];
      FilledOrder storage targetOrder = filledOrders[request.epoch][targetRedeemOrder.idx];

      if (request.position == Position.Over) {
        targetOrder.underRedeemed += targetRedeemOrder.unit;
        totalPaidAmount += targetOrder.underPrice * targetRedeemOrder.unit * PRICE_UNIT;
      } else {
        targetOrder.overRedeemed += targetRedeemOrder.unit;
        totalPaidAmount += targetOrder.overPrice * targetRedeemOrder.unit * PRICE_UNIT;
      }
    }
  }

  function processRedeemTransfer(
    IClearingHouse clearingHouse,
    address redeemVault,
    address user,
    uint256 unit,
    uint256 totalPaidAmount,
    uint256 redeemFee
  ) internal {
    uint256 totalAmount = 100 * unit * PRICE_UNIT;
    uint256 redeemAmount = totalAmount - totalPaidAmount;
    uint256 fee = (redeemAmount * redeemFee) / BASE;
    uint256 redeemAmountAfterFee = redeemAmount - fee;

    clearingHouse.subtractUserBalance(redeemVault, redeemAmountAfterFee);
    clearingHouse.addUserBalance(user, redeemAmountAfterFee);
  }
}
