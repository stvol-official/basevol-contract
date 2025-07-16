// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVaultManager } from "../interfaces/IVaultManager.sol";
import { IClearingHouse } from "../interfaces/IClearingHouse.sol";
import { Round, FilledOrder, SettlementResult, WithdrawalRequest, Coupon, PriceInfo } from "../types/Types.sol";

library BaseVolStrikeStorage {
  struct Layout {
    IERC20 token; // Prediction token
    IPyth oracle;
    IVaultManager vaultManager;
    IClearingHouse clearingHouse;
    address adminAddress; // address of the admin
    address operatorAddress; // address of the operator
    uint256 commissionfee; // commission rate (e.g. 200 = 2%, 150 = 1.50%)
    mapping(uint256 => Round) rounds;
    mapping(uint256 => FilledOrder[]) filledOrders; // key: epoch
    uint256 lastFilledOrderId;
    uint256 lastSubmissionTime;
    uint256 lastSettledFilledOrderId; // globally
    mapping(uint256 => uint256) lastSettledFilledOrderIndex; // by round(epoch)
    mapping(uint256 => SettlementResult) settlementResults; // key: filled order idx
    mapping(uint256 => PriceInfo) priceInfos; // productId => PriceInfo
    mapping(bytes32 => uint256) priceIdToProductId; // priceId => productId
    uint256 priceIdCount;
    uint256 redeemFee; // redeem fee (e.g. 1000000 = 1 usdc, 1e6 = 1 usdc)
    address redeemVault; // vault address for redeeming
    /* IMPROTANT: you can add new variables here */
  }
}
