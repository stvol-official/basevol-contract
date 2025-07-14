// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IPyth } from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { PythStructs } from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import { BaseVolStrikeStorage } from "../storage/BaseVolStrikeStorage.sol";
import { PriceUpdateData } from "../types/Types.sol";

library EpochLib {
  uint256 private constant BUFFER_SECONDS = 600; // 10 * 60 (10min)

  error EpochHasNotStartedYet();
  error InvalidEpoch();

  function epochAt(
    uint256 timestamp,
    uint256 startTimestamp,
    uint256 intervalSeconds
  ) internal pure returns (uint256) {
    if (timestamp < startTimestamp) revert EpochHasNotStartedYet();
    uint256 elapsedSeconds = timestamp - startTimestamp;
    uint256 epoch = elapsedSeconds / intervalSeconds;
    return epoch;
  }

  function epochTimes(
    uint256 epoch,
    uint256 startTimestamp,
    uint256 intervalSeconds
  ) internal pure returns (uint256 startTime, uint256 endTime) {
    if (epoch < 0) revert InvalidEpoch();
    startTime = startTimestamp + (epoch * intervalSeconds);
    endTime = startTime + intervalSeconds;
    return (startTime, endTime);
  }

  function getPythPrices(
    BaseVolStrikeStorage.Layout storage $,
    PriceUpdateData[] memory updateDataWithIds,
    uint64 timestamp
  ) internal returns (PythStructs.PriceFeed[] memory) {
    bytes[] memory updateData = new bytes[](updateDataWithIds.length);
    bytes32[] memory priceIds = new bytes32[](updateDataWithIds.length);

    for (uint256 i = 0; i < updateDataWithIds.length; i++) {
      updateData[i] = updateDataWithIds[i].priceData;
      priceIds[i] = $.priceInfos[updateDataWithIds[i].productId].priceId;
    }

    uint fee = $.oracle.getUpdateFee(updateData);
    return
      $.oracle.parsePriceFeedUpdates{ value: fee }(
        updateData,
        priceIds,
        timestamp,
        timestamp + uint64(BUFFER_SECONDS)
      );
  }

  function currentEpoch(
    uint256 startTimestamp,
    uint256 intervalSeconds
  ) internal view returns (uint256) {
    return epochAt(block.timestamp, startTimestamp, intervalSeconds);
  }
}
