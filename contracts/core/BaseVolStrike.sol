// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
pragma abicoder v2;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IClearingHouse } from "../interfaces/IClearingHouse.sol";
import { BaseVolStrikeStorage } from "../storage/BaseVolStrikeStorage.sol";
import { Round, FilledOrder, Position, Coupon, WithdrawalRequest, ProductRound, SettlementResult, WinPosition, PriceInfo, PriceUpdateData, ManualPriceData, RedeemRequest, TargetRedeemOrder, SettlementAmounts, PositionAmounts, TieAmounts } from "../types/Types.sol";
import { IBaseVolErrors } from "../errors/BaseVolErrors.sol";
import { SettlementLib } from "../libraries/SettlementLib.sol";
import { RedeemLib } from "../libraries/RedeemLib.sol";
import { RoundLib } from "../libraries/RoundLib.sol";
import { AdminLib } from "../libraries/AdminLib.sol";
import { ViewLib } from "../libraries/ViewLib.sol";
import { ManualLib } from "../libraries/ManualLib.sol";
import { OrderLib } from "../libraries/OrderLib.sol";
import { EpochLib } from "../libraries/EpochLib.sol";
import { SelfOrderLib } from "../libraries/SelfOrderLib.sol";

abstract contract BaseVolStrike is
  Initializable,
  UUPSUpgradeable,
  OwnableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable,
  IBaseVolErrors
{
  using SafeERC20 for IERC20;

  uint256 private constant PRICE_UNIT = 1e6;

  // Abstract functions
  function _getStartTimestamp() internal pure virtual returns (uint256);
  function _getIntervalSeconds() internal pure virtual returns (uint256);
  function _getStorageSlot() internal pure virtual returns (bytes32);

  function _getStorage() internal pure returns (BaseVolStrikeStorage.Layout storage $) {
    bytes32 slot = _getStorageSlot();
    assembly {
      $.slot := slot
    }
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(
    address _usdcAddress,
    address _oracleAddress,
    address _adminAddress,
    address _operatorAddress,
    uint256 _commissionfee,
    address _clearingHouseAddress
  ) public initializer {
    __UUPSUpgradeable_init();
    __Ownable_init(msg.sender);
    __Pausable_init();
    __ReentrancyGuard_init();

    if (_commissionfee > 500) revert InvalidCommissionFee();

    BaseVolStrikeStorage.Layout storage $ = _getStorage();

    $.token = IERC20(_usdcAddress);
    $.oracle = IPyth(_oracleAddress);
    $.clearingHouse = IClearingHouse(_clearingHouseAddress);
    $.adminAddress = _adminAddress;
    $.operatorAddress = _operatorAddress;
    $.commissionfee = _commissionfee;

    AdminLib.addPriceId(
      $,
      0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43,
      0,
      "BTC/USD"
    );
    AdminLib.addPriceId(
      $,
      0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace,
      1,
      "ETH/USD"
    );
  }

  function currentEpoch() external view returns (uint256) {
    return EpochLib.currentEpoch(_getStartTimestamp(), _getIntervalSeconds());
  }

  function executeRound(
    PriceUpdateData[] calldata updateDataWithIds,
    uint64 initDate,
    bool skipSettlement
  ) external payable whenNotPaused {
    BaseVolStrikeStorage.Layout storage $ = _getStorage();
    if (msg.sender != $.operatorAddress) revert InvalidAddress();
    if ((initDate - _getStartTimestamp()) % _getIntervalSeconds() != 0) revert InvalidInitDate();

    PythStructs.PriceFeed[] memory feeds = EpochLib.getPythPrices($, updateDataWithIds, initDate);
    uint256 startEpoch = EpochLib.epochAt(initDate, _getStartTimestamp(), _getIntervalSeconds());
    uint256 currentEpochNumber = EpochLib.epochAt(
      block.timestamp,
      _getStartTimestamp(),
      _getIntervalSeconds()
    );
    uint256 prevEpoch = startEpoch - 1;

    // Start current round
    RoundLib.startCurrentRound(
      $.rounds,
      startEpoch,
      currentEpochNumber,
      initDate,
      _getIntervalSeconds(),
      feeds,
      updateDataWithIds
    );

    // End previous round
    RoundLib.endPreviousRound($.rounds, prevEpoch, initDate, feeds, updateDataWithIds);

    if (!skipSettlement) {
      _settleFilledOrders($.rounds[prevEpoch]);
    }
  }

  function settleFilledOrders(uint256 epoch, uint256 size) public returns (uint256) {
    BaseVolStrikeStorage.Layout storage $ = _getStorage();
    if (msg.sender != $.operatorAddress) revert InvalidAddress();

    OrderLib.validateSettleRequest($, epoch);

    Round storage round = $.rounds[epoch];
    FilledOrder[] storage orders = $.filledOrders[epoch];
    uint256 endIndex = orders.length;
    uint256 settledCount = 0;

    for (uint i = 0; i < endIndex; i++) {
      FilledOrder storage order = orders[i];
      uint256 fee = _settleFilledOrder(round, order);
      if (fee > 0) {
        settledCount++;
      }
      if (settledCount >= size) {
        break;
      }
    }

    return orders.length - endIndex;
  }

  function countUnsettledFilledOrders(uint256 epoch) external view returns (uint256) {
    BaseVolStrikeStorage.Layout storage $ = _getStorage();
    return OrderLib.countUnsettledFilledOrders($, epoch);
  }

  function redeemFilledOrder(RedeemRequest calldata request) external {
    BaseVolStrikeStorage.Layout storage $ = _getStorage();
    if (msg.sender != $.operatorAddress) revert InvalidAddress();
    FilledOrder storage order = $.filledOrders[request.epoch][request.idx];

    // Validate request
    RedeemLib.validateRedeemRequest(order, request);
    RedeemLib.validateTargetRedeemOrders($.filledOrders, request);

    // Update redemptions
    uint256 paidAmount = RedeemLib.updateOrderRedemptions(order, request);
    uint256 totalPaidAmount = RedeemLib.updateTargetOrderRedemptions(
      $.filledOrders,
      request,
      paidAmount
    );

    // Process transfer
    RedeemLib.processRedeemTransfer(
      $.clearingHouse,
      $.redeemVault,
      request.user,
      request.unit,
      totalPaidAmount,
      $.redeemFee
    );
  }

  function submitFilledOrders(FilledOrder[] calldata transactions) external nonReentrant {
    BaseVolStrikeStorage.Layout storage $ = _getStorage();
    if (msg.sender != $.operatorAddress) revert InvalidAddress();

    OrderLib.submitFilledOrders($, transactions, address(this));

    // Handle settlement for already settled rounds
    for (uint i = 0; i < transactions.length; i++) {
      FilledOrder calldata order = transactions[i];
      Round storage round = $.rounds[order.epoch];
      if (round.isSettled) {
        FilledOrder[] storage orders = $.filledOrders[order.epoch];
        _settleFilledOrder(round, orders[orders.length - 1]);
      }
    }
  }

  function _settleFilledOrder(
    Round storage round,
    FilledOrder storage order
  ) internal returns (uint256) {
    if (order.isSettled) return 0;

    uint256 strikePrice = (round.startPrice[order.productId] * order.strike) / 10000;
    bool isOverWin = strikePrice < round.endPrice[order.productId];
    bool isUnderWin = strikePrice > round.endPrice[order.productId];

    // Handle invalid orders first
    if (order.overPrice + order.underPrice != 100) {
      return _handleInvalidOrder(order);
    }

    uint256 collectedFee;

    BaseVolStrikeStorage.Layout storage $ = _getStorage();

    if (order.overUser == order.underUser) {
      collectedFee = SelfOrderLib.handleSelfOrder($, order, isOverWin, isUnderWin);
    } else if (isOverWin) {
      collectedFee = _processWin(order.overUser, order.underUser, order, WinPosition.Over);
    } else if (isUnderWin) {
      collectedFee = _processWin(order.underUser, order.overUser, order, WinPosition.Under);
    } else {
      collectedFee = SelfOrderLib.handleTieOrder($, order);
    }

    order.isSettled = true;
    return collectedFee;
  }

  function _handleInvalidOrder(FilledOrder storage order) internal returns (uint256) {
    BaseVolStrikeStorage.Layout storage $ = _getStorage();
    OrderLib.transferRedeemedAmountsToVault($, order);

    if (order.overUser != order.underUser) {
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
    } else {
      $.clearingHouse.releaseFromEscrow(
        address(this),
        order.overUser,
        order.epoch,
        order.idx,
        100 * order.unit * PRICE_UNIT,
        0
      );
    }

    return 0;
  }

  function _processWin(
    address winner,
    address loser,
    FilledOrder storage order,
    WinPosition winPosition
  ) internal returns (uint256) {
    BaseVolStrikeStorage.Layout storage $ = _getStorage();
    return SettlementLib.processWin($, winner, loser, order, winPosition);
  }

  function pause() external whenNotPaused {
    BaseVolStrikeStorage.Layout storage $ = _getStorage();
    if (msg.sender != $.adminAddress) revert InvalidAddress();
    _pause();
  }

  function retrieveMisplacedETH() external {
    BaseVolStrikeStorage.Layout storage $ = _getStorage();
    if (msg.sender != $.adminAddress) revert InvalidAddress();
    AdminLib.retrieveMisplacedETH($, address(this));
  }

  function retrieveMisplacedTokens(address _token) external {
    BaseVolStrikeStorage.Layout storage $ = _getStorage();
    if (msg.sender != $.adminAddress) revert InvalidAddress();
    AdminLib.retrieveMisplacedTokens($, _token, address(this));
  }

  function unpause() external whenPaused {
    BaseVolStrikeStorage.Layout storage $ = _getStorage();
    if (msg.sender != $.adminAddress) revert InvalidAddress();
    _unpause();
  }

  function setOperator(address _operatorAddress) external {
    BaseVolStrikeStorage.Layout storage $ = _getStorage();
    if (msg.sender != $.adminAddress) revert InvalidAddress();
    AdminLib.setOperator($, _operatorAddress);
  }

  function setOracle(address _oracle) external whenPaused {
    BaseVolStrikeStorage.Layout storage $ = _getStorage();
    if (msg.sender != $.adminAddress) revert InvalidAddress();
    AdminLib.setOracle($, _oracle);
  }

  function setCommissionfee(uint256 _commissionfee) external whenPaused {
    BaseVolStrikeStorage.Layout storage $ = _getStorage();
    if (msg.sender != $.adminAddress) revert InvalidAddress();
    AdminLib.setCommissionfee($, _commissionfee);
  }

  function setAdmin(address _adminAddress) external onlyOwner {
    BaseVolStrikeStorage.Layout storage $ = _getStorage();
    AdminLib.setAdmin($, _adminAddress);
  }

  function setToken(address _token) external {
    BaseVolStrikeStorage.Layout storage $ = _getStorage();
    if (msg.sender != $.adminAddress) revert InvalidAddress();
    AdminLib.setToken($, _token);
  }

  function addPriceId(bytes32 _priceId, uint256 _productId, string calldata _symbol) external {
    BaseVolStrikeStorage.Layout storage $ = _getStorage();
    if (msg.sender != $.operatorAddress) revert InvalidAddress();
    AdminLib.addPriceId($, _priceId, _productId, _symbol);
  }

  function setPriceInfo(PriceInfo calldata priceInfo) external {
    BaseVolStrikeStorage.Layout storage $ = _getStorage();
    if (msg.sender != $.operatorAddress) revert InvalidAddress();
    AdminLib.setPriceInfo($, priceInfo);
  }

  /* public views */

  function filledOrders(uint256 epoch) public view returns (FilledOrder[] memory) {
    return _getStorage().filledOrders[epoch];
  }

  /* internal functions */

  function _settleFilledOrders(Round storage round) internal {
    BaseVolStrikeStorage.Layout storage $ = _getStorage();

    if (round.epoch == 0 || round.startTimestamp == 0 || round.endTimestamp == 0) return;

    FilledOrder[] storage orders = $.filledOrders[round.epoch];
    for (uint i = 0; i < orders.length; i++) {
      FilledOrder storage order = orders[i];
      _settleFilledOrder(round, order);
    }
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

  function setManualRoundEndPrices(
    ManualPriceData[] calldata manualPrices,
    uint64 initDate,
    bool skipSettlement
  ) external {
    BaseVolStrikeStorage.Layout storage $ = _getStorage();
    if (msg.sender != $.operatorAddress) revert InvalidAddress();

    Round storage problemRound = ManualLib.setManualRoundEndPrices(
      $,
      manualPrices,
      initDate,
      _getStartTimestamp(),
      _getIntervalSeconds()
    );

    if (!skipSettlement) {
      _settleFilledOrders(problemRound);
    }
  }

  function releaseEpochEscrow(uint256 epoch) external {
    BaseVolStrikeStorage.Layout storage $ = _getStorage();
    if (msg.sender != $.operatorAddress) revert InvalidAddress();
    ManualLib.releaseEpochEscrow($, epoch);
  }

  function setRedeemFee(uint256 _redeemFee) external {
    BaseVolStrikeStorage.Layout storage $ = _getStorage();
    if (msg.sender != $.adminAddress) revert InvalidAddress();
    AdminLib.setRedeemFee($, _redeemFee);
  }

  function setRedeemVault(address _redeemVault) external {
    BaseVolStrikeStorage.Layout storage $ = _getStorage();
    if (msg.sender != $.adminAddress) revert InvalidAddress();
    AdminLib.setRedeemVault($, _redeemVault);
  }

  function redeemVault() external view returns (address) {
    return _getStorage().redeemVault;
  }

  function redeemFee() external view returns (uint256) {
    return _getStorage().redeemFee;
  }
}
