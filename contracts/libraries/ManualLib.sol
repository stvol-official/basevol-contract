// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { BaseVolStrikeStorage } from "../storage/BaseVolStrikeStorage.sol";
import { Round, FilledOrder, ManualPriceData, SettlementResult, WinPosition } from "../types/Types.sol";
library ManualLib {
  error InvalidInitDate();
  error InvalidEpoch();
  error EpochHasNotStartedYet();
  uint256 private constant PRICE_UNIT = 1e6;

  event EndRound(uint256 indexed epoch, uint256 productId, uint256 price, uint256 timestamp);

  function setManualRoundEndPrices(
    BaseVolStrikeStorage.Layout storage $,
    ManualPriceData[] calldata manualPrices,
    uint64 initDate,
    uint256 startTimestamp,
    uint256 intervalSeconds
  ) internal returns (Round storage problemRound) {
    if ((initDate - startTimestamp) % intervalSeconds != 0) revert InvalidInitDate();

    uint256 problemEpoch = _epochAt(initDate, startTimestamp, intervalSeconds);
    uint256 currentEpochNumber = _epochAt(block.timestamp, startTimestamp, intervalSeconds);

    if (problemEpoch >= currentEpochNumber) revert InvalidEpoch();

    // end problem round
    problemRound = $.rounds[problemEpoch];
    Round storage nextRound = $.rounds[problemEpoch + 1];
    if (!nextRound.isStarted) {
      nextRound.epoch = problemEpoch + 1;
      nextRound.startTimestamp = initDate + intervalSeconds;
      nextRound.endTimestamp = nextRound.startTimestamp + intervalSeconds;
      nextRound.isStarted = true;
      nextRound.isSettled = false;
    }

    if (
      problemRound.epoch == problemEpoch &&
      problemRound.startTimestamp > 0 &&
      problemRound.isStarted
    ) {
      problemRound.endTimestamp = initDate + intervalSeconds;

      for (uint i = 0; i < manualPrices.length; i++) {
        ManualPriceData calldata priceData = manualPrices[i];
        problemRound.endPrice[priceData.productId] = priceData.price;
        if (
          nextRound.epoch <= currentEpochNumber && nextRound.startPrice[priceData.productId] == 0
        ) {
          nextRound.startPrice[priceData.productId] = priceData.price;
        }

        emit EndRound(problemEpoch, priceData.productId, priceData.price, initDate);
      }
      problemRound.isSettled = true;
    }
  }

  function releaseEpochEscrow(BaseVolStrikeStorage.Layout storage $, uint256 epoch) internal {
    Round storage round = $.rounds[epoch];
    FilledOrder[] storage orders = $.filledOrders[epoch];

    for (uint i = 0; i < orders.length; i++) {
      FilledOrder memory order = orders[i];
      if (!order.isSettled) {
        if (order.overUser == order.underUser) {
          $.clearingHouse.releaseFromEscrow(
            address(this),
            order.overUser,
            order.epoch,
            order.idx,
            100 * order.unit * PRICE_UNIT,
            0
          );
        } else {
          $.clearingHouse.releaseFromEscrow(
            address(this),
            order.overUser,
            order.epoch,
            order.idx,
            order.overPrice * order.unit * PRICE_UNIT,
            0
          );
          $.clearingHouse.releaseFromEscrow(
            address(this),
            order.underUser,
            order.epoch,
            order.idx,
            order.underPrice * order.unit * PRICE_UNIT,
            0
          );
          order.isSettled = true;

          $.settlementResults[order.idx] = SettlementResult({
            idx: order.idx,
            winPosition: WinPosition.Invalid,
            winAmount: 0,
            feeRate: 0,
            fee: 0
          });
        }
      }
    }
    round.isSettled = true;
  }

  function _epochAt(
    uint256 timestamp,
    uint256 startTimestamp,
    uint256 intervalSeconds
  ) private pure returns (uint256) {
    if (timestamp < startTimestamp) revert EpochHasNotStartedYet();
    uint256 elapsedSeconds = timestamp - startTimestamp;
    uint256 epoch = elapsedSeconds / intervalSeconds;
    return epoch;
  }
}
