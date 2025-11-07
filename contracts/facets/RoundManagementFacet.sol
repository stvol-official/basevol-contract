// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibBaseVolStrike } from "../libraries/LibBaseVolStrike.sol";
import { LibDiamond } from "../libraries/LibDiamond.sol";
import { PriceUpdateData, PriceData, Round, FilledOrder, Position } from "../types/Types.sol";
import { PythStructs } from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PythLazer } from "../libraries/PythLazer.sol";
import { PythLazerLib } from "../libraries/PythLazerLib.sol";
import { PriceLazerData } from "../types/Types.sol";

contract RoundManagementFacet {
  using LibBaseVolStrike for LibBaseVolStrike.DiamondStorage;
  using SafeERC20 for IERC20;

  uint256 private constant PRICE_UNIT = 1e6;
  uint256 private constant BUFFER_SECONDS = 600; // 10 * 60 (10min)
  uint256 private constant MAX_PRICE_AGE = 300; // 5 * 60 (5min) - maximum age of price data in seconds
  uint256 private constant MAX_PRICE_DEVIATION_BPS = 5000; // 50% maximum price deviation (basis points)
  uint256 private constant BPS_DENOMINATOR = 10000;

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
    PriceLazerData calldata priceLazerData,
    uint64 initDate,
    bool skipSettlement
  ) external payable onlyOperator {
    if ((initDate - _getStartTimestamp()) % _getIntervalSeconds() != 0)
      revert LibBaseVolStrike.InvalidInitDate();

    PriceData[] memory priceData = _processPythLazerPriceUpdate(priceLazerData);

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

    for (uint i = 0; i < priceData.length; i++) {
      uint256 productId = priceData[i].productId;
      uint64 pythPrice = priceData[i].price;
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

    for (uint i = 0; i < priceData.length; i++) {
      uint256 productId = priceData[i].productId;
      uint64 pythPrice = priceData[i].price;
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

        // Vector 1: Price validation
        require(data.price > 0, "Invalid price: must be greater than zero");

        // Check price deviation from start price (if start price exists)
        uint256 startPrice = problemRound.startPrice[data.productId];
        if (startPrice > 0) {
          uint256 deviation;
          if (data.price > startPrice) {
            deviation = ((data.price - startPrice) * BPS_DENOMINATOR) / startPrice;
          } else {
            deviation = ((startPrice - data.price) * BPS_DENOMINATOR) / startPrice;
          }
          require(deviation <= MAX_PRICE_DEVIATION_BPS, "Price deviation exceeds 50%");
        }

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

  function _processPythLazerPriceUpdate(
    PriceLazerData memory priceLazerData
  ) internal returns (PriceData[] memory) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();

    uint256 verificationFee = bvs.pythLazer.verification_fee();
    if (msg.value < verificationFee) {
      revert LibBaseVolStrike.InsufficientVerificationFee();
    }

    (bytes memory payload, ) = bvs.pythLazer.verifyUpdate{ value: verificationFee }(
      priceLazerData.priceData
    );
    if (msg.value > verificationFee) {
      payable(msg.sender).transfer(msg.value - verificationFee);
    }

    (uint64 publishTime, PythLazerLib.Channel channel, uint8 feedsLen, uint16 pos) = PythLazerLib
      .parsePayloadHeader(payload);

    if (channel != PythLazerLib.Channel.RealTime) {
      revert LibBaseVolStrike.InvalidChannel();
    }

    PriceData[] memory tempData = new PriceData[](feedsLen);
    uint256 validCount = 0;

    for (uint8 i = 0; i < feedsLen; i++) {
      uint32 feedId;
      uint8 numProperties;
      (feedId, numProperties, pos) = PythLazerLib.parseFeedHeader(payload, pos);

      uint64 price = 0;
      bool priceFound = false;

      for (uint8 j = 0; j < numProperties; j++) {
        PythLazerLib.PriceFeedProperty property;
        (property, pos) = PythLazerLib.parseFeedProperty(payload, pos);
        if (property == PythLazerLib.PriceFeedProperty.Price) {
          (price, pos) = PythLazerLib.parseFeedValueUint64(payload, pos);
          priceFound = true;
        }
      }

      if (priceFound && price > 0) {
        uint256 productId = type(uint256).max;
        for (uint256 k = 0; k < priceLazerData.mappings.length; k++) {
          if (priceLazerData.mappings[k].priceFeedId == uint256(feedId)) {
            productId = priceLazerData.mappings[k].productId;
            break;
          }
        }

        // Check if productId is valid and price is reasonable
        if (productId != type(uint256).max) {
          tempData[validCount] = PriceData({ productId: productId, price: price });
          validCount++;
        }
      }
    }

    PriceData[] memory priceData = new PriceData[](validCount);

    for (uint256 i = 0; i < validCount; i++) {
      priceData[i] = tempData[i];
    }

    return priceData;
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
