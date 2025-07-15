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

  function redeemFilledOrder(RedeemRequest calldata request) external onlyOperator {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    FilledOrder storage order = bvs.filledOrders[request.epoch][request.idx];
    if (order.idx != request.idx) revert LibBaseVolStrike.InvalidId();
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
      FilledOrder storage targetOrder = bvs.filledOrders[request.epoch][targetRedeemOrder.idx];
      if (targetOrder.idx != targetRedeemOrder.idx) revert LibBaseVolStrike.InvalidId();
      if (targetOrder.isSettled) revert LibBaseVolStrike.AlreadySettled();

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

    uint256 orderPrice = request.position == Position.Over ? order.overPrice : order.underPrice;
    uint256 paidAmount = 0;
    if (request.position == Position.Over) {
      order.overRedeemed += request.unit;
      paidAmount = orderPrice * request.unit * PRICE_UNIT;
    } else {
      order.underRedeemed += request.unit;
      paidAmount = orderPrice * request.unit * PRICE_UNIT;
    }

    for (uint i = 0; i < request.targetRedeemOrders.length; i++) {
      TargetRedeemOrder calldata targetRedeemOrder = request.targetRedeemOrders[i];
      FilledOrder storage targetOrder = bvs.filledOrders[request.epoch][targetRedeemOrder.idx];
      if (request.position == Position.Over) {
        targetOrder.underRedeemed += targetRedeemOrder.unit;
        paidAmount += targetOrder.underPrice * targetRedeemOrder.unit * PRICE_UNIT;
      } else {
        targetOrder.overRedeemed += targetRedeemOrder.unit;
        paidAmount += targetOrder.overPrice * targetRedeemOrder.unit * PRICE_UNIT;
      }
    }

    uint256 totalAmount = 100 * request.unit * PRICE_UNIT;
    uint256 redeemAmount = totalAmount - paidAmount;
    uint256 fee = (redeemAmount * bvs.redeemFee) / BASE;
    uint256 redeemAmountAfterFee = redeemAmount - fee;

    bvs.clearingHouse.subtractUserBalance(bvs.redeemVault, redeemAmountAfterFee);
    bvs.clearingHouse.addUserBalance(request.user, redeemAmountAfterFee);
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
