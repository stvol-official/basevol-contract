// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibBaseVolStrike } from "../libraries/LibBaseVolStrike.sol";
import { LibDiamond } from "../../diamond-common/libraries/LibDiamond.sol";
import { RedeemRequest, TargetRedeemOrder, FilledOrder, Position, RedeemPairs } from "../../types/Types.sol";

contract RedemptionFacet {
  using LibBaseVolStrike for LibBaseVolStrike.DiamondStorage;

  uint256 private constant PRICE_UNIT = 1e6;
  uint256 private constant BASE = 10000; // 100%

  event RedeemPairsEvent(
    uint256 idx,
    uint256 epoch,
    uint256 productId,
    uint256 strike,
    uint256 unit,
    address user,
    uint256 totalPaidPrice,
    uint256 profitCommission,
    uint256 redeemCommission,
    uint256 totalCommission,
    uint256 finalRedemptionAmount
  );

  event OrderTerminatedEvent(
    uint256 idx,
    uint256 epoch,
    uint256 productId,
    uint256 strike,
    uint256 unit
  );

  modifier onlyOperator() {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    require(msg.sender == bvs.operatorAddress, "Only operator");
    _;
  }

  modifier onlyAdmin() {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    require(msg.sender == bvs.adminAddress, "Only admin");
    _;
  }

  // Helper function to find FilledOrder by idx in a given epoch
  function _findFilledOrderByIdx(
    uint256 epoch,
    uint256 idx
  ) internal view returns (FilledOrder storage) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    FilledOrder[] storage epochOrders = bvs.filledOrders[epoch];

    for (uint256 i = 0; i < epochOrders.length; i++) {
      if (epochOrders[i].idx == idx) {
        return epochOrders[i];
      }
    }
    revert LibBaseVolStrike.InvalidId();
  }

  function redeemPairs(RedeemPairs[] calldata pairs) external onlyOperator {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();

    for (uint256 i = 0; i < pairs.length; i++) {
      RedeemPairs calldata pair = pairs[i];

      // Validate that sum of overOrders units equals pair.unit
      uint256 totalOverUnits = 0;
      for (uint256 j = 0; j < pair.overOrders.length; j++) {
        totalOverUnits += pair.overOrders[j].unit;
      }
      if (totalOverUnits != pair.unit) revert LibBaseVolStrike.InvalidOverUnitsSum();

      // Validate that sum of underOrders units equals pair.unit
      uint256 totalUnderUnits = 0;
      for (uint256 j = 0; j < pair.underOrders.length; j++) {
        totalUnderUnits += pair.underOrders[j].unit;
      }
      if (totalUnderUnits != pair.unit) revert LibBaseVolStrike.InvalidUnderUnitsSum();

      // Validate each over order
      for (uint256 j = 0; j < pair.overOrders.length; j++) {
        FilledOrder storage overOrder = _findFilledOrderByIdx(pair.epoch, pair.overOrders[j].idx);
        if (overOrder.strike != pair.strike) revert LibBaseVolStrike.InvalidStrike();
        if (overOrder.productId != pair.productId) revert LibBaseVolStrike.InvalidProductId();
        if (overOrder.overUser != pair.user) revert LibBaseVolStrike.InvalidAddress();
        if (overOrder.unit - overOrder.overRedeemed < pair.overOrders[j].unit)
          revert LibBaseVolStrike.InsufficientOverRedeemable();
        if (overOrder.isSettled) revert LibBaseVolStrike.AlreadySettled();
      }

      // Validate each under order
      for (uint256 j = 0; j < pair.underOrders.length; j++) {
        FilledOrder storage underOrder = _findFilledOrderByIdx(pair.epoch, pair.underOrders[j].idx);
        if (underOrder.strike != pair.strike) revert LibBaseVolStrike.InvalidStrike();
        if (underOrder.productId != pair.productId) revert LibBaseVolStrike.InvalidProductId();
        if (underOrder.underUser != pair.user) revert LibBaseVolStrike.InvalidAddress();
        if (underOrder.unit - underOrder.underRedeemed < pair.underOrders[j].unit)
          revert LibBaseVolStrike.InsufficientUnderRedeemable();
        if (underOrder.isSettled) revert LibBaseVolStrike.AlreadySettled();
      }

      uint256 baseRedemptionAmount = pair.unit * 100 * PRICE_UNIT;
      uint256 totalPaidPrice = 0;
      for (uint256 j = 0; j < pair.overOrders.length; j++) {
        FilledOrder storage overOrder = _findFilledOrderByIdx(pair.epoch, pair.overOrders[j].idx);
        totalPaidPrice += overOrder.overPrice * pair.overOrders[j].unit * PRICE_UNIT;
        overOrder.overRedeemed += pair.overOrders[j].unit;
      }
      for (uint256 j = 0; j < pair.underOrders.length; j++) {
        FilledOrder storage underOrder = _findFilledOrderByIdx(pair.epoch, pair.underOrders[j].idx);
        totalPaidPrice += underOrder.underPrice * pair.underOrders[j].unit * PRICE_UNIT;
        underOrder.underRedeemed += pair.underOrders[j].unit;
      }

      uint256 profitCommission = 0;
      if (totalPaidPrice < baseRedemptionAmount) {
        uint256 profitAmount = baseRedemptionAmount - totalPaidPrice;
        profitCommission = (profitAmount * bvs.commissionfee) / BASE;
      }

      uint256 redeemCommission = bvs.redeemFee * pair.unit;

      uint256 totalCommission = profitCommission + redeemCommission;
      if (totalCommission > baseRedemptionAmount)
        revert LibBaseVolStrike.CommissionExceedsRedemption();

      uint256 finalRedemptionAmount = baseRedemptionAmount - totalCommission;

      bvs.clearingHouse.subtractUserBalance(bvs.redeemVault, finalRedemptionAmount);
      bvs.clearingHouse.addUserBalance(pair.user, finalRedemptionAmount);

      emit RedeemPairsEvent(
        pair.idx,
        pair.epoch,
        pair.productId,
        pair.strike,
        pair.unit,
        pair.user,
        totalPaidPrice,
        profitCommission,
        redeemCommission,
        totalCommission,
        finalRedemptionAmount
      );

      // redeem 된 filled order 들을 순회하면서 over/under 둘 다 모두 redeem 되었는지 확인
      for (uint256 j = 0; j < pair.overOrders.length; j++) {
        FilledOrder storage overOrder = _findFilledOrderByIdx(pair.epoch, pair.overOrders[j].idx);
        if (
          overOrder.overRedeemed == overOrder.unit &&
          overOrder.underRedeemed == overOrder.unit &&
          overOrder.isSettled == false
        ) {
          _settleRedeemedOrder(overOrder);
        }
      }
      for (uint256 j = 0; j < pair.underOrders.length; j++) {
        FilledOrder storage underOrder = _findFilledOrderByIdx(pair.epoch, pair.underOrders[j].idx);
        if (
          underOrder.underRedeemed == underOrder.unit &&
          underOrder.overRedeemed == underOrder.unit &&
          underOrder.isSettled == false
        ) {
          _settleRedeemedOrder(underOrder);
        }
      }
    }
  }

  function _settleRedeemedOrder(FilledOrder storage order) internal {
    if (
      order.overRedeemed != order.unit ||
      order.underRedeemed != order.unit ||
      order.isSettled == true
    ) {
      return;
    }

    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();

    bvs.clearingHouse.settleEscrowWithFee(
      address(this),
      order.overUser,
      bvs.redeemVault,
      order.epoch,
      order.unit * order.overPrice * PRICE_UNIT,
      order.idx,
      0
    );

    bvs.clearingHouse.settleEscrowWithFee(
      address(this),
      order.underUser,
      bvs.redeemVault,
      order.epoch,
      order.unit * order.underPrice * PRICE_UNIT,
      order.idx,
      0
    );

    order.isSettled = true;

    emit OrderTerminatedEvent(order.idx, order.epoch, order.productId, order.strike, order.unit);
  }

  function setRedeemFee(uint256 _redeemFee) external onlyAdmin {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    bvs.redeemFee = _redeemFee;
  }

  function setRedeemVault(address _redeemVault) external onlyAdmin {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    bvs.redeemVault = _redeemVault;
  }

  function redeemVault() external view returns (address) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    return bvs.redeemVault;
  }

  function redeemFee() external view returns (uint256) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    return bvs.redeemFee;
  }
}
