// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { BaseVolStrikeStorage } from "../storage/BaseVolStrikeStorage.sol";
import { FilledOrder, WinPosition, SettlementResult, TieAmounts, PositionAmounts } from "../types/Types.sol";
import { SettlementLib } from "./SettlementLib.sol";

library SelfOrderLib {
  uint256 private constant PRICE_UNIT = 1e6;

  function handleSelfOrder(
    BaseVolStrikeStorage.Layout storage $,
    FilledOrder storage order,
    bool isOverWin,
    bool isUnderWin
  ) internal returns (uint256) {
    WinPosition winPosition = isOverWin
      ? WinPosition.Over
      : isUnderWin
        ? WinPosition.Under
        : WinPosition.Tie;

    if (winPosition == WinPosition.Tie) {
      return handleSelfTieOrder($, order);
    } else {
      return handleSelfWinLoseOrder($, order, winPosition, isOverWin);
    }
  }

  function handleSelfTieOrder(
    BaseVolStrikeStorage.Layout storage $,
    FilledOrder storage order
  ) internal returns (uint256) {
    TieAmounts memory amounts = TieAmounts({
      overAmountToUser: (order.unit - order.overRedeemed) * order.overPrice * PRICE_UNIT,
      overAmountToVault: order.overRedeemed * order.overPrice * PRICE_UNIT,
      underAmountToUser: (order.unit - order.underRedeemed) * order.underPrice * PRICE_UNIT,
      underAmountToVault: order.underRedeemed * order.underPrice * PRICE_UNIT
    });

    // Release entire escrow amount
    $.clearingHouse.releaseFromEscrow(
      address(this),
      order.overUser,
      order.epoch,
      order.idx,
      100 * order.unit * PRICE_UNIT,
      0
    );

    // Transfer redeem amounts to vault
    if (amounts.overAmountToVault > 0) {
      $.clearingHouse.subtractUserBalance(order.overUser, amounts.overAmountToVault);
      $.clearingHouse.addUserBalance($.redeemVault, amounts.overAmountToVault);
    }
    if (amounts.underAmountToVault > 0) {
      $.clearingHouse.subtractUserBalance(order.overUser, amounts.underAmountToVault);
      $.clearingHouse.addUserBalance($.redeemVault, amounts.underAmountToVault);
    }

    $.settlementResults[order.idx] = SettlementResult({
      idx: order.idx,
      winPosition: WinPosition.Tie,
      winAmount: 0,
      feeRate: $.commissionfee,
      fee: 0
    });

    return 0;
  }

  function handleSelfWinLoseOrder(
    BaseVolStrikeStorage.Layout storage $,
    FilledOrder storage order,
    WinPosition winPosition,
    bool isOverWin
  ) internal returns (uint256) {
    uint256 redeemedUnit = isOverWin ? order.overRedeemed : order.underRedeemed;

    // Calculate amounts
    uint256 loserPositionTotalAmount = (isOverWin ? order.underPrice : order.overPrice) *
      order.unit *
      PRICE_UNIT;
    uint256 totalFee = (loserPositionTotalAmount * $.commissionfee) / 10000;

    uint256 userPortionUnit = order.unit - redeemedUnit;
    uint256 vaultPortionUnit = redeemedUnit;

    PositionAmounts memory amounts = SettlementLib.calculateSelfOrderAmounts(
      order,
      isOverWin,
      userPortionUnit,
      vaultPortionUnit,
      totalFee
    );

    // Release entire escrow amount first
    $.clearingHouse.releaseFromEscrow(
      address(this),
      order.overUser,
      order.epoch,
      order.idx,
      100 * order.unit * PRICE_UNIT,
      totalFee
    );

    // Transfer redeem vault amounts
    if (amounts.totalVaultAmount > 0) {
      $.clearingHouse.subtractUserBalance(order.overUser, amounts.totalVaultAmount);
      $.clearingHouse.addUserBalance($.redeemVault, amounts.totalVaultAmount);
    }

    $.settlementResults[order.idx] = SettlementResult({
      idx: order.idx,
      winPosition: winPosition,
      winAmount: loserPositionTotalAmount,
      feeRate: $.commissionfee,
      fee: totalFee
    });

    return totalFee;
  }

  function handleTieOrder(
    BaseVolStrikeStorage.Layout storage $,
    FilledOrder storage order
  ) internal returns (uint256) {
    TieAmounts memory amounts = TieAmounts({
      overAmountToUser: (order.unit - order.overRedeemed) * order.overPrice * PRICE_UNIT,
      overAmountToVault: order.overRedeemed * order.overPrice * PRICE_UNIT,
      underAmountToUser: (order.unit - order.underRedeemed) * order.underPrice * PRICE_UNIT,
      underAmountToVault: order.underRedeemed * order.underPrice * PRICE_UNIT
    });

    // Release over position escrow
    $.clearingHouse.releaseFromEscrow(
      address(this),
      order.overUser,
      order.epoch,
      order.idx,
      order.overPrice * order.unit * PRICE_UNIT,
      0
    );

    // Release under position escrow
    $.clearingHouse.releaseFromEscrow(
      address(this),
      order.underUser,
      order.epoch,
      order.idx,
      order.underPrice * order.unit * PRICE_UNIT,
      0
    );

    // Transfer redeem amounts to vault
    if (amounts.overAmountToVault > 0) {
      $.clearingHouse.subtractUserBalance(order.overUser, amounts.overAmountToVault);
      $.clearingHouse.addUserBalance($.redeemVault, amounts.overAmountToVault);
    }
    if (amounts.underAmountToVault > 0) {
      $.clearingHouse.subtractUserBalance(order.underUser, amounts.underAmountToVault);
      $.clearingHouse.addUserBalance($.redeemVault, amounts.underAmountToVault);
    }

    $.settlementResults[order.idx] = SettlementResult({
      idx: order.idx,
      winPosition: WinPosition.Tie,
      winAmount: 0,
      feeRate: $.commissionfee,
      fee: 0
    });

    return 0;
  }
}
