// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { BaseVolStrikeStorage } from "../storage/BaseVolStrikeStorage.sol";
import { FilledOrder, Round } from "../types/Types.sol";
import { IClearingHouse } from "../interfaces/IClearingHouse.sol";

library OrderLib {
  uint256 private constant PRICE_UNIT = 1e6;

  error InvalidId();

  function submitFilledOrders(
    BaseVolStrikeStorage.Layout storage $,
    FilledOrder[] calldata transactions,
    address contractAddress
  ) internal {
    if ($.lastFilledOrderId + 1 > transactions[0].idx) revert InvalidId();

    for (uint i = 0; i < transactions.length; i++) {
      FilledOrder calldata order = transactions[i];

      // Calculate required amounts
      uint256 overAmount = order.overPrice * order.unit * PRICE_UNIT;
      uint256 underAmount = order.underPrice * order.unit * PRICE_UNIT;

      // Lock in escrow for both parties
      $.clearingHouse.lockInEscrow(
        contractAddress,
        order.overUser,
        overAmount,
        order.epoch,
        order.idx,
        true
      );
      $.clearingHouse.lockInEscrow(
        contractAddress,
        order.underUser,
        underAmount,
        order.epoch,
        order.idx,
        true
      );

      FilledOrder[] storage orders = $.filledOrders[order.epoch];
      orders.push(order);

      Round storage round = $.rounds[order.epoch];
      if (round.isSettled) {
        // Note: _settleFilledOrder would be called from main contract
      }
    }
    $.lastFilledOrderId = transactions[transactions.length - 1].idx;
    $.lastSubmissionTime = block.timestamp;
  }

  function transferRedeemedAmountsToVault(
    BaseVolStrikeStorage.Layout storage $,
    FilledOrder storage order
  ) internal {
    if (order.underRedeemed > 0) {
      uint256 redeemedAmount = order.underPrice * order.underRedeemed * PRICE_UNIT;
      $.clearingHouse.subtractUserBalance(order.underUser, redeemedAmount);
      $.clearingHouse.addUserBalance($.redeemVault, redeemedAmount);
    }
    if (order.overRedeemed > 0) {
      uint256 redeemedAmount = order.overPrice * order.overRedeemed * PRICE_UNIT;
      $.clearingHouse.subtractUserBalance(order.overUser, redeemedAmount);
      $.clearingHouse.addUserBalance($.redeemVault, redeemedAmount);
    }
  }

  function countUnsettledFilledOrders(
    BaseVolStrikeStorage.Layout storage $,
    uint256 epoch
  ) internal view returns (uint256) {
    FilledOrder[] storage orders = $.filledOrders[epoch];
    uint256 unsettledCount = 0;
    for (uint i = 0; i < orders.length; i++) {
      if (!orders[i].isSettled) {
        unsettledCount++;
      }
    }
    return unsettledCount;
  }

  function validateSettleRequest(
    BaseVolStrikeStorage.Layout storage $,
    uint256 epoch
  ) internal view {
    Round storage round = $.rounds[epoch];
    if (round.epoch == 0 || round.startTimestamp == 0 || round.endTimestamp == 0) {
      revert InvalidRound();
    }
    if (round.startPrice[0] == 0 || round.endPrice[0] == 0) {
      revert InvalidRoundPrice();
    }
  }

  error InvalidRound();
  error InvalidRoundPrice();
}
