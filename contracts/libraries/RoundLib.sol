// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import { Round, PriceUpdateData, PriceInfo } from "../types/Types.sol";

library RoundLib {
  uint256 private constant BUFFER_SECONDS = 600; // 10 * 60 (10min)

  event StartRound(uint256 indexed epoch, uint256 productId, uint256 price, uint256 timestamp);
  event EndRound(uint256 indexed epoch, uint256 productId, uint256 price, uint256 timestamp);

  function startCurrentRound(
    mapping(uint256 => Round) storage rounds,
    uint256 startEpoch,
    uint256 currentEpochNumber,
    uint64 initDate,
    uint256 intervalSeconds,
    PythStructs.PriceFeed[] memory feeds,
    PriceUpdateData[] calldata updateDataWithIds
  ) internal {
    Round storage round = rounds[startEpoch];
    if (startEpoch == currentEpochNumber && !round.isStarted) {
      round.epoch = startEpoch;
      round.startTimestamp = initDate;
      round.endTimestamp = initDate + intervalSeconds;
      round.isStarted = true;
    }

    for (uint i = 0; i < feeds.length; i++) {
      uint256 productId = updateDataWithIds[i].productId;
      uint64 pythPrice = uint64(feeds[i].price.price);
      if (round.startPrice[productId] == 0) {
        round.startPrice[productId] = pythPrice;
        emit StartRound(startEpoch, productId, pythPrice, initDate);
      }
    }
  }

  function endPreviousRound(
    mapping(uint256 => Round) storage rounds,
    uint256 prevEpoch,
    uint64 initDate,
    PythStructs.PriceFeed[] memory feeds,
    PriceUpdateData[] calldata updateDataWithIds
  ) internal {
    Round storage prevRound = rounds[prevEpoch];
    if (
      prevRound.epoch == prevEpoch &&
      prevRound.startTimestamp > 0 &&
      prevRound.isStarted &&
      !prevRound.isSettled
    ) {
      prevRound.endTimestamp = initDate;
      prevRound.isSettled = true;
    }

    for (uint i = 0; i < feeds.length; i++) {
      uint256 productId = updateDataWithIds[i].productId;
      uint64 pythPrice = uint64(feeds[i].price.price);
      if (prevRound.endPrice[productId] == 0) {
        prevRound.endPrice[productId] = pythPrice;
        emit EndRound(prevEpoch, productId, pythPrice, initDate);
      }
    }
  }

  function getPythPrices(
    IPyth oracle,
    mapping(uint256 => PriceInfo) storage priceInfos,
    PriceUpdateData[] memory updateDataWithIds,
    uint64 timestamp
  ) internal returns (PythStructs.PriceFeed[] memory) {
    bytes[] memory updateData = new bytes[](updateDataWithIds.length);
    bytes32[] memory priceIds = new bytes32[](updateDataWithIds.length);

    for (uint256 i = 0; i < updateDataWithIds.length; i++) {
      updateData[i] = updateDataWithIds[i].priceData;
      priceIds[i] = priceInfos[updateDataWithIds[i].productId].priceId;
    }

    uint fee = oracle.getUpdateFee(updateData);
    return
      oracle.parsePriceFeedUpdates{ value: fee }(
        updateData,
        priceIds,
        timestamp,
        timestamp + uint64(BUFFER_SECONDS)
      );
  }
}
