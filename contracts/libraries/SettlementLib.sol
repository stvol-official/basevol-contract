// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IClearingHouse } from "../interfaces/IClearingHouse.sol";
import { BaseVolStrikeStorage } from "../storage/BaseVolStrikeStorage.sol";
import { FilledOrder, WinPosition, SettlementResult, SettlementAmounts, PositionAmounts, TieAmounts } from "../types/Types.sol";

library SettlementLib {
  uint256 private constant PRICE_UNIT = 1e6;
  uint256 private constant BASE = 10000; // 100%

  function calculateWinAmounts(
    FilledOrder storage order,
    address winner,
    address loser,
    uint256 commissionfee
  ) internal view returns (SettlementAmounts memory) {
    uint256 winnerAmount = order.overUser == winner
      ? order.overPrice * order.unit * PRICE_UNIT
      : order.underPrice * order.unit * PRICE_UNIT;

    uint256 loserAmount = order.overUser == loser
      ? order.overPrice * order.unit * PRICE_UNIT
      : order.underPrice * order.unit * PRICE_UNIT;

    uint256 totalFee = (loserAmount * commissionfee) / BASE;

    return
      SettlementAmounts({
        winnerAmount: winnerAmount,
        loserAmount: loserAmount,
        totalFee: totalFee,
        winAmount: loserAmount,
        collectedFee: totalFee
      });
  }

  function calculateWinPositionAmounts(
    FilledOrder storage order,
    address winner,
    address loser,
    uint256 redeemedUnit,
    uint256 totalFee
  ) internal view returns (PositionAmounts memory) {
    uint256 winnerAmountToUser = ((order.unit - redeemedUnit) *
      (order.overUser == winner ? order.overPrice : order.underPrice) *
      PRICE_UNIT);
    uint256 winnerAmountToVault = (redeemedUnit *
      (order.overUser == winner ? order.overPrice : order.underPrice) *
      PRICE_UNIT);

    uint256 loserFeeForWinner = (totalFee * (order.unit - redeemedUnit)) / order.unit;
    uint256 loserFeeForVault = (totalFee * redeemedUnit) / order.unit;

    uint256 loserAmountToWinner = ((order.unit - redeemedUnit) *
      (order.overUser == loser ? order.overPrice : order.underPrice) *
      PRICE_UNIT) - loserFeeForWinner;
    uint256 loserAmountToVault = (redeemedUnit *
      (order.overUser == loser ? order.overPrice : order.underPrice) *
      PRICE_UNIT) - loserFeeForVault;

    return
      PositionAmounts({
        winnerAmountToUser: winnerAmountToUser,
        winnerAmountToVault: winnerAmountToVault,
        loserAmountToWinner: loserAmountToWinner,
        loserAmountToVault: loserAmountToVault,
        totalVaultAmount: winnerAmountToVault + loserAmountToVault
      });
  }

  function calculateSelfOrderAmounts(
    FilledOrder storage order,
    bool isOverWin,
    uint256 userPortionUnit,
    uint256 vaultPortionUnit,
    uint256 totalFee
  ) internal view returns (PositionAmounts memory) {
    uint256 winnerAmountToUser = (userPortionUnit *
      (isOverWin ? order.overPrice : order.underPrice) *
      PRICE_UNIT);
    uint256 winnerAmountToVault = (vaultPortionUnit *
      (isOverWin ? order.overPrice : order.underPrice) *
      PRICE_UNIT);

    uint256 loserFeeForUser = (totalFee * userPortionUnit) / order.unit;
    uint256 loserFeeForVault = (totalFee * vaultPortionUnit) / order.unit;

    uint256 loserAmountToUser = (userPortionUnit *
      (isOverWin ? order.underPrice : order.overPrice) *
      PRICE_UNIT) - loserFeeForUser;
    uint256 loserAmountToVault = (vaultPortionUnit *
      (isOverWin ? order.underPrice : order.overPrice) *
      PRICE_UNIT) - loserFeeForVault;

    return
      PositionAmounts({
        winnerAmountToUser: winnerAmountToUser,
        winnerAmountToVault: winnerAmountToVault,
        loserAmountToWinner: loserAmountToUser,
        loserAmountToVault: loserAmountToVault,
        totalVaultAmount: winnerAmountToVault + loserAmountToVault
      });
  }

  function processWinEscrowRelease(
    IClearingHouse clearingHouse,
    FilledOrder storage order,
    address winner,
    address loser,
    SettlementAmounts memory amounts
  ) internal {
    // Release winner's escrow (no fee)
    clearingHouse.releaseFromEscrow(
      address(this),
      winner,
      order.epoch,
      order.idx,
      amounts.winnerAmount,
      0
    );

    // Release loser's escrow (with total fee)
    clearingHouse.releaseFromEscrow(
      address(this),
      loser,
      order.epoch,
      order.idx,
      amounts.loserAmount,
      amounts.totalFee
    );
  }

  function processWinTransfers(
    IClearingHouse clearingHouse,
    address redeemVault,
    address winner,
    address loser,
    PositionAmounts memory posAmounts
  ) internal {
    // Transfer loser's amount to winner (after fee)
    if (posAmounts.loserAmountToWinner > 0) {
      clearingHouse.subtractUserBalance(loser, posAmounts.loserAmountToWinner);
      clearingHouse.addUserBalance(winner, posAmounts.loserAmountToWinner);
    }

    // Transfer redeem amounts to vault
    if (posAmounts.totalVaultAmount > 0) {
      if (posAmounts.winnerAmountToVault > 0) {
        clearingHouse.subtractUserBalance(winner, posAmounts.winnerAmountToVault);
      }
      if (posAmounts.loserAmountToVault > 0) {
        clearingHouse.subtractUserBalance(loser, posAmounts.loserAmountToVault);
      }
      clearingHouse.addUserBalance(redeemVault, posAmounts.totalVaultAmount);
    }
  }

  function processWin(
    BaseVolStrikeStorage.Layout storage $,
    address winner,
    address loser,
    FilledOrder storage order,
    WinPosition winPosition
  ) internal returns (uint256) {
    SettlementAmounts memory amounts = calculateWinAmounts(order, winner, loser, $.commissionfee);

    uint256 redeemedUnit = (winPosition == WinPosition.Over)
      ? order.overRedeemed
      : order.underRedeemed;

    PositionAmounts memory posAmounts = calculateWinPositionAmounts(
      order,
      winner,
      loser,
      redeemedUnit,
      amounts.totalFee
    );

    processWinEscrowRelease($.clearingHouse, order, winner, loser, amounts);
    processWinTransfers($.clearingHouse, $.redeemVault, winner, loser, posAmounts);

    $.settlementResults[order.idx] = SettlementResult({
      idx: order.idx,
      winPosition: winPosition,
      winAmount: amounts.loserAmount,
      feeRate: $.commissionfee,
      fee: amounts.totalFee
    });

    return amounts.totalFee;
  }
}
