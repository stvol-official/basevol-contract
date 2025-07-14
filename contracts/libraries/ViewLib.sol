// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { BaseVolStrikeStorage } from "../storage/BaseVolStrikeStorage.sol";
import { FilledOrder, SettlementResult, ProductRound, Round, PriceInfo } from "../types/Types.sol";
import { IClearingHouse } from "../interfaces/IClearingHouse.sol";

library ViewLib {
  function getBalances(
    BaseVolStrikeStorage.Layout storage $,
    address user
  ) internal view returns (uint256, uint256, uint256) {
    uint256 depositBalance = $.clearingHouse.userBalances(user);
    uint256 couponBalance = $.clearingHouse.couponBalanceOf(user);
    uint256 totalBalance = depositBalance + couponBalance;
    return (depositBalance, couponBalance, totalBalance);
  }

  function getRound(
    BaseVolStrikeStorage.Layout storage $,
    uint256 epoch,
    uint256 productId,
    uint256 startTimestamp,
    uint256 intervalSeconds
  ) internal view returns (ProductRound memory) {
    Round storage round = $.rounds[epoch];
    if (round.epoch == 0) {
      uint256 startTime = startTimestamp + (epoch * intervalSeconds);
      uint256 endTime = startTime + intervalSeconds;
      return
        ProductRound({
          epoch: epoch,
          startTimestamp: startTime,
          endTimestamp: endTime,
          isStarted: false,
          isSettled: false,
          startPrice: 0,
          endPrice: 0
        });
    }
    return
      ProductRound({
        epoch: round.epoch,
        startTimestamp: round.startTimestamp,
        endTimestamp: round.endTimestamp,
        isStarted: round.isStarted,
        isSettled: round.isSettled,
        startPrice: round.startPrice[productId],
        endPrice: round.endPrice[productId]
      });
  }

  function getFilledOrdersWithResult(
    BaseVolStrikeStorage.Layout storage $,
    uint256 epoch,
    uint256 chunkSize,
    uint256 offset
  ) internal view returns (FilledOrder[] memory, SettlementResult[] memory) {
    FilledOrder[] memory orders = $.filledOrders[epoch];
    if (offset >= orders.length) {
      return (new FilledOrder[](0), new SettlementResult[](0));
    }
    uint256 end = offset + chunkSize;
    if (end > orders.length) {
      end = orders.length;
    }
    FilledOrder[] memory chunkedOrders = new FilledOrder[](end - offset);
    SettlementResult[] memory chunkedResults = new SettlementResult[](end - offset);
    for (uint i = offset; i < end; i++) {
      chunkedOrders[i - offset] = orders[i];
      chunkedResults[i - offset] = $.settlementResults[orders[i].idx];
    }
    return (chunkedOrders, chunkedResults);
  }

  function getUserFilledOrders(
    BaseVolStrikeStorage.Layout storage $,
    uint256 epoch,
    address user
  ) internal view returns (FilledOrder[] memory) {
    FilledOrder[] storage orders = $.filledOrders[epoch];
    uint cnt = 0;
    for (uint i = 0; i < orders.length; i++) {
      FilledOrder storage order = orders[i];
      if (order.overUser == user || order.underUser == user) {
        cnt++;
      }
    }
    FilledOrder[] memory userOrders = new FilledOrder[](cnt);
    uint idx = 0;
    for (uint i = 0; i < orders.length; i++) {
      FilledOrder storage order = orders[i];
      if (order.overUser == user || order.underUser == user) {
        userOrders[idx] = order;
        idx++;
      }
    }
    return userOrders;
  }

  function getPriceInfos(
    BaseVolStrikeStorage.Layout storage $
  ) internal view returns (PriceInfo[] memory) {
    PriceInfo[] memory priceInfoArray = new PriceInfo[]($.priceIdCount);
    for (uint256 i = 0; i < $.priceIdCount; i++) {
      priceInfoArray[i] = $.priceInfos[i];
    }
    return priceInfoArray;
  }
}
