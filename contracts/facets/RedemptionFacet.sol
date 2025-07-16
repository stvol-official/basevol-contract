// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibBaseVolStrike } from "../libraries/LibBaseVolStrike.sol";
import { LibDiamond } from "../libraries/LibDiamond.sol";
import { RedeemRequest, TargetRedeemOrder, FilledOrder, Position } from "../types/Types.sol";

contract RedemptionFacet {
  using LibBaseVolStrike for LibBaseVolStrike.DiamondStorage;

  uint256 private constant PRICE_UNIT = 1e6;
  uint256 private constant BASE = 10000; // 100%

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
        uint256 mainPrice = order.overPrice * pairUnits;
        uint256 targetPrice = targetOrder.underPrice * pairUnits;
        totalPaidPrice += mainPrice + targetPrice;
      } else {
        // User has Under position in main order, Over position in target order
        uint256 mainPrice = order.underPrice * pairUnits;
        uint256 targetPrice = targetOrder.overPrice * pairUnits;
        totalPaidPrice += mainPrice + targetPrice;
      }
    }

    // Calculate profit commission
    uint256 profitCommission = 0;
    if (totalPaidPrice < 100 * totalUnits) {
      uint256 profitAmount = (100 * totalUnits - totalPaidPrice);
      profitCommission = (profitAmount * bvs.commissionfee * PRICE_UNIT) / BASE;
    }

    // Calculate redeem commission (fixed amount)
    uint256 redeemCommission = bvs.redeemFee * totalUnits;

    // Calculate final redemption amount
    uint256 totalCommission = profitCommission + redeemCommission;
    if (totalCommission > baseRedemptionAmount) revert LibBaseVolStrike.InvalidAmount();

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
