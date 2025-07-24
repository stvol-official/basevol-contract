// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibBaseVolStrike } from "../libraries/LibBaseVolStrike.sol";
import { LibDiamond } from "../libraries/LibDiamond.sol";
import { PriceUpdateData, PriceData, Round, FilledOrder, Position } from "../types/Types.sol";
import { PythStructs } from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RoundManagementFacet {
  using LibBaseVolStrike for LibBaseVolStrike.DiamondStorage;
  using SafeERC20 for IERC20;

  uint256 private constant PRICE_UNIT = 1e6;
  uint256 private constant BUFFER_SECONDS = 600; // 10 * 60 (10min)

  event StartRound(uint256 indexed epoch, uint256 productId, uint256 price, uint256 timestamp);
  event EndRound(uint256 indexed epoch, uint256 productId, uint256 price, uint256 timestamp);
  event RoundSettled(uint256 indexed epoch, uint256 orderCount, uint256 collectedFee);

  modifier onlyOperator() {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    require(msg.sender == bvs.operatorAddress, "Only operator");
    _;
  }

  function currentEpoch() external view returns (uint256) {
    return _epochAt(block.timestamp);
  }

  function executeRound(
    PriceUpdateData[] calldata updateDataWithIds,
    uint64 initDate,
    bool skipSettlement
  ) external payable onlyOperator {
    if ((initDate - _getStartTimestamp()) % _getIntervalSeconds() != 0)
      revert LibBaseVolStrike.InvalidInitDate();

    PythStructs.PriceFeed[] memory feeds = _getPythPrices(updateDataWithIds, initDate);

    uint256 startEpoch = _epochAt(initDate);
    uint256 currentEpochNumber = _epochAt(block.timestamp);

    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();

    // start current round
    Round storage round = bvs.rounds[startEpoch];
    if (startEpoch == currentEpochNumber && !round.isStarted) {
      round.epoch = startEpoch;
      round.startTimestamp = initDate;
      round.endTimestamp = initDate + _getIntervalSeconds();
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

    // end prev round (if started)
    uint256 prevEpoch = startEpoch - 1;
    Round storage prevRound = bvs.rounds[prevEpoch];
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

    if (!skipSettlement) {
      _settleFilledOrders(prevRound);
    }
  }

  function setManualRoundEndPrices(
    PriceData[] calldata priceData,
    uint64 initDate,
    bool skipSettlement
  ) external onlyOperator {
    if ((initDate - _getStartTimestamp()) % _getIntervalSeconds() != 0)
      revert LibBaseVolStrike.InvalidInitDate();

    uint256 problemEpoch = _epochAt(initDate);
    uint256 currentEpochNumber = _epochAt(block.timestamp);

    if (problemEpoch >= currentEpochNumber) revert LibBaseVolStrike.InvalidEpoch();

    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();

    // end problem round
    Round storage problemRound = bvs.rounds[problemEpoch];
    Round storage nextRound = bvs.rounds[problemEpoch + 1];
    if (!nextRound.isStarted) {
      nextRound.epoch = problemEpoch + 1;
      nextRound.startTimestamp = initDate + _getIntervalSeconds();
      nextRound.endTimestamp = nextRound.startTimestamp + _getIntervalSeconds();
      nextRound.isStarted = true;
      nextRound.isSettled = false;
    }

    if (
      problemRound.epoch == problemEpoch &&
      problemRound.startTimestamp > 0 &&
      problemRound.isStarted
    ) {
      problemRound.endTimestamp = initDate + _getIntervalSeconds();

      for (uint i = 0; i < priceData.length; i++) {
        PriceData calldata data = priceData[i];
        problemRound.endPrice[data.productId] = data.price;
        if (nextRound.epoch <= currentEpochNumber && nextRound.startPrice[data.productId] == 0) {
          nextRound.startPrice[data.productId] = data.price;
        }

        emit EndRound(problemEpoch, data.productId, data.price, initDate);
      }
      problemRound.isSettled = true;
    }

    if (!skipSettlement) {
      _settleFilledOrders(problemRound);
    }
  }

  function releaseEpochEscrow(uint256 epoch) external onlyOperator {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    Round storage round = bvs.rounds[epoch];
    FilledOrder[] storage orders = bvs.filledOrders[epoch];

    for (uint i = 0; i < orders.length; i++) {
      FilledOrder memory order = orders[i];
      if (!order.isSettled) {
        if (order.overUser == order.underUser) {
          bvs.clearingHouse.releaseFromEscrow(
            address(this),
            order.overUser,
            order.epoch,
            order.idx,
            100 * order.unit * PRICE_UNIT,
            0
          );
        } else {
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
          order.isSettled = true;

          // bvs.settlementResults[order.idx] = SettlementResult({
          //     idx: order.idx,
          //     winPosition: WinPosition.Invalid,
          //     winAmount: 0,
          //     feeRate: 0,
          //     fee: 0
          // });
        }
      }
    }
    round.isSettled = true;
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

  function _epochAt(uint256 timestamp) internal view returns (uint256) {
    if (timestamp < _getStartTimestamp()) revert LibBaseVolStrike.EpochHasNotStartedYet();
    uint256 elapsedSeconds = timestamp - _getStartTimestamp();
    uint256 epoch = elapsedSeconds / _getIntervalSeconds();
    return epoch;
  }

  function _getPythPrices(
    PriceUpdateData[] memory updateDataWithIds,
    uint64 timestamp
  ) internal returns (PythStructs.PriceFeed[] memory) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();

    bytes[] memory updateData = new bytes[](updateDataWithIds.length);
    bytes32[] memory priceIds = new bytes32[](updateDataWithIds.length);

    for (uint256 i = 0; i < updateDataWithIds.length; i++) {
      updateData[i] = updateDataWithIds[i].priceData;
      priceIds[i] = bvs.priceInfos[updateDataWithIds[i].productId].priceId;
    }

    uint fee = bvs.oracle.getUpdateFee(updateData);
    return
      bvs.oracle.parsePriceFeedUpdates{ value: fee }(
        updateData,
        priceIds,
        timestamp,
        timestamp + uint64(BUFFER_SECONDS)
      );
  }

  function _settleFilledOrders(Round storage round) internal {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();

    if (round.epoch == 0 || round.startTimestamp == 0 || round.endTimestamp == 0) return;

    uint256 collectedFee = 0;
    FilledOrder[] storage orders = bvs.filledOrders[round.epoch];
    for (uint i = 0; i < orders.length; i++) {
      FilledOrder storage order = orders[i];
      collectedFee += LibBaseVolStrike.settleFilledOrder(round, order);
    }

    emit RoundSettled(round.epoch, orders.length, collectedFee);
  }
}
