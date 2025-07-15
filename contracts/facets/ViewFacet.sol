// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibBaseVolStrike } from "../libraries/LibBaseVolStrike.sol";
import { LibDiamond } from "../libraries/LibDiamond.sol";
import { Round, FilledOrder, ProductRound, SettlementResult, PriceInfo } from "../types/Types.sol";

contract ViewFacet {
  using LibBaseVolStrike for LibBaseVolStrike.DiamondStorage;

  function commissionfee() public view returns (uint256) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    return bvs.commissionfee;
  }

  function addresses() public view returns (address, address, address, address) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    return (bvs.adminAddress, bvs.operatorAddress, address(bvs.clearingHouse), address(bvs.token));
  }

  function balances(address user) public view returns (uint256, uint256, uint256) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    uint256 depositBalance = bvs.clearingHouse.userBalances(user);
    uint256 couponBalance = bvs.clearingHouse.couponBalanceOf(user);
    uint256 totalBalance = depositBalance + couponBalance;
    return (depositBalance, couponBalance, totalBalance);
  }

  function rounds(uint256 epoch, uint256 productId) public view returns (ProductRound memory) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    Round storage round = bvs.rounds[epoch];
    if (round.epoch == 0) {
      (uint256 startTime, uint256 endTime) = _epochTimes(epoch);
      return
        // return virtual value
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
      // return storage value
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

  function filledOrders(uint256 epoch) public view returns (FilledOrder[] memory) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    return bvs.filledOrders[epoch];
  }

  function filledOrdersWithResult(
    uint256 epoch,
    uint256 chunkSize,
    uint256 offset
  ) public view returns (FilledOrder[] memory, SettlementResult[] memory) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    FilledOrder[] memory orders = bvs.filledOrders[epoch];
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
      chunkedResults[i - offset] = bvs.settlementResults[orders[i].idx];
    }
    return (chunkedOrders, chunkedResults);
  }

  function userFilledOrders(
    uint256 epoch,
    address user
  ) public view returns (FilledOrder[] memory) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    FilledOrder[] storage orders = bvs.filledOrders[epoch];
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

  function lastFilledOrderId() public view returns (uint256) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    return bvs.lastFilledOrderId;
  }

  function lastSettledFilledOrderId() public view returns (uint256) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    return bvs.lastSettledFilledOrderId;
  }

  function priceInfos() external view returns (PriceInfo[] memory) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    PriceInfo[] memory priceInfoArray = new PriceInfo[](bvs.priceIdCount);
    for (uint256 i = 0; i < bvs.priceIdCount; i++) {
      priceInfoArray[i] = bvs.priceInfos[i];
    }
    return priceInfoArray;
  }

  // Internal functions
  function _getStartTimestamp() internal view returns (uint256) {
    LibBaseVolStrike.DiamondStorage storage ds = LibBaseVolStrike.diamondStorage();
    return ds.startTimestamp;
  }

  function _getIntervalSeconds() internal view returns (uint256) {
    LibBaseVolStrike.DiamondStorage storage ds = LibBaseVolStrike.diamondStorage();
    return ds.intervalSeconds;
  }

  function _epochTimes(uint256 epoch) internal view returns (uint256 startTime, uint256 endTime) {
    if (epoch < 0) revert LibBaseVolStrike.InvalidEpoch();
    startTime = _getStartTimestamp() + (epoch * _getIntervalSeconds());
    endTime = startTime + _getIntervalSeconds();
    return (startTime, endTime);
  }
}
