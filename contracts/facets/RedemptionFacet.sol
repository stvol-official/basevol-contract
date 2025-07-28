// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibBaseVolStrike } from "../libraries/LibBaseVolStrike.sol";
import { LibDiamond } from "../libraries/LibDiamond.sol";
import { RedeemRequest, TargetRedeemOrder, FilledOrder, Position, RedeemPairs } from "../types/Types.sol";

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
    }
  }

  function redeemFilledOrder(RedeemRequest calldata request) external onlyOperator {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    FilledOrder storage order = _findFilledOrderByIdx(request.epoch, request.idx);
    if (order.isSettled) revert LibBaseVolStrike.AlreadySettled();

    if (request.position == Position.Over) {
      if (order.overUser != request.user) revert LibBaseVolStrike.InvalidAddress();
      if (request.unit > order.unit - order.overRedeemed) revert LibBaseVolStrike.InvalidAmount();
    } else {
      if (order.underUser != request.user) revert LibBaseVolStrike.InvalidAddress();
      if (request.unit > order.unit - order.underRedeemed) revert LibBaseVolStrike.InvalidAmount();
    }

    uint256 totalRedeemed = 0;
    for (uint i = 0; i < request.targetRedeemOrders.length; i++) {
      totalRedeemed += request.targetRedeemOrders[i].unit;
      TargetRedeemOrder calldata targetRedeemOrder = request.targetRedeemOrders[i];
      FilledOrder storage targetOrder = _findFilledOrderByIdx(request.epoch, targetRedeemOrder.idx);
      if (targetOrder.isSettled) revert LibBaseVolStrike.AlreadySettled();

      if (order.strike != targetOrder.strike) revert LibBaseVolStrike.InvalidStrike();

      if (request.position == Position.Over) {
        if (targetOrder.underUser != request.user) revert LibBaseVolStrike.InvalidAddress();
        if (targetRedeemOrder.unit > targetOrder.unit - targetOrder.underRedeemed)
          revert LibBaseVolStrike.InvalidAmount();
      } else {
        if (targetOrder.overUser != request.user) revert LibBaseVolStrike.InvalidAddress();
        if (targetRedeemOrder.unit > targetOrder.unit - targetOrder.overRedeemed)
          revert LibBaseVolStrike.InvalidAmount();
      }
    }
    if (totalRedeemed != request.unit) revert LibBaseVolStrike.InvalidAmount();

    // Total units being redeemed (each unit is a hedge pair: over + under)
    uint256 totalUnits = request.unit;

    // Calculate base redemption amount (100 USDC per unit)
    uint256 baseRedemptionAmount = totalUnits * 100 * PRICE_UNIT;
    require(
      totalUnits == 0 || baseRedemptionAmount / PRICE_UNIT / totalUnits == 100,
      "Multiplication overflow"
    );

    // Calculate total paid price by user for the hedge positions
    // Each unit consists of 1 over position + 1 under position from different orders
    uint256 totalPaidPrice = 0;

    // For each unit being redeemed, add the price from main order and corresponding target order
    for (uint i = 0; i < request.targetRedeemOrders.length; i++) {
      TargetRedeemOrder calldata targetRedeemOrder = request.targetRedeemOrders[i];
      FilledOrder storage targetOrder = _findFilledOrderByIdx(request.epoch, targetRedeemOrder.idx);

      // Each target order unit pairs with main order units
      uint256 pairUnits = targetRedeemOrder.unit; // Should match part of request.unit

      if (request.position == Position.Over) {
        // User has Over position in main order, Under position in target order
        uint256 mainPrice = order.overPrice * pairUnits * PRICE_UNIT;
        uint256 targetPrice = targetOrder.underPrice * pairUnits * PRICE_UNIT;
        totalPaidPrice += mainPrice + targetPrice;
      } else {
        // User has Under position in main order, Over position in target order
        uint256 mainPrice = order.underPrice * pairUnits * PRICE_UNIT;
        uint256 targetPrice = targetOrder.overPrice * pairUnits * PRICE_UNIT;
        totalPaidPrice += mainPrice + targetPrice;
      }
    }

    // Calculate profit commission
    uint256 profitCommission = 0;
    if (totalPaidPrice < 100 * totalUnits * PRICE_UNIT) {
      uint256 profitAmount = (100 * totalUnits * PRICE_UNIT - totalPaidPrice);
      profitCommission = (profitAmount * bvs.commissionfee) / BASE;
    }

    // Calculate redeem commission (fixed amount)
    uint256 redeemCommission = bvs.redeemFee * totalUnits;

    // Calculate final redemption amount
    uint256 totalCommission = profitCommission + redeemCommission;
    if (totalCommission > baseRedemptionAmount)
      revert LibBaseVolStrike.CommissionExceedsRedemption();

    uint256 finalRedemptionAmount = baseRedemptionAmount - totalCommission;

    // Update redeemed amounts
    if (request.position == Position.Over) {
      order.overRedeemed += request.unit;
    } else {
      order.underRedeemed += request.unit;
    }

    for (uint i = 0; i < request.targetRedeemOrders.length; i++) {
      TargetRedeemOrder calldata targetRedeemOrder = request.targetRedeemOrders[i];
      FilledOrder storage targetOrder = _findFilledOrderByIdx(request.epoch, targetRedeemOrder.idx);
      if (request.position == Position.Over) {
        targetOrder.underRedeemed += targetRedeemOrder.unit;
      } else {
        targetOrder.overRedeemed += targetRedeemOrder.unit;
      }
    }

    // Transfer final redemption amount from redeem vault to user
    bvs.clearingHouse.subtractUserBalance(bvs.redeemVault, finalRedemptionAmount);
    bvs.clearingHouse.addUserBalance(request.user, finalRedemptionAmount);
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
