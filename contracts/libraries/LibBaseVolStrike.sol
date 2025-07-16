// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVaultManager } from "../interfaces/IVaultManager.sol";
import { IClearingHouse } from "../interfaces/IClearingHouse.sol";
import { Round, FilledOrder, SettlementResult, WithdrawalRequest, Coupon, PriceInfo, RedeemRequest, TargetRedeemOrder, Position, PriceUpdateData, ManualPriceData } from "../types/Types.sol";

library LibBaseVolStrike {
  bytes32 constant DIAMOND_STORAGE_POSITION = keccak256("basevol.diamond.storage");

  struct DiamondStorage {
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
    uint256 redeemFee; // redeem fee (e.g. 200 = 2%, 150 = 1.50%)
    address redeemVault; // vault address for redeeming
    uint256 startTimestamp; // Contract start timestamp
    uint256 intervalSeconds; // Round interval in seconds
    /* IMPROTANT: you can add new variables here */
  }

  function diamondStorage() internal pure returns (DiamondStorage storage ds) {
    bytes32 position = DIAMOND_STORAGE_POSITION;
    assembly {
      ds.slot := position
    }
  }

  // Import all necessary errors from BaseVolErrors
  error InvalidAddress();
  error InvalidCommissionFee();
  error InvalidInitDate();
  error InvalidRound();
  error InvalidRoundPrice();
  error InvalidId();
  error AlreadySettled();
  error InvalidAmount();
  error InvalidStrike();
  error InvalidPriceId();
  error InvalidSymbol();
  error PriceIdAlreadyExists();
  error ProductIdAlreadyExists();
  error InvalidTokenAddress();
  error InvalidEpoch();
  error EpochHasNotStartedYet();

  // Access control modifiers
  modifier onlyAdmin() {
    require(msg.sender == diamondStorage().adminAddress, "Only admin");
    _;
  }

  modifier onlyOperator() {
    require(msg.sender == diamondStorage().operatorAddress, "Only operator");
    _;
  }

  // onlyOwner modifier will be implemented in individual facets using LibDiamond.enforceIsContractOwner()
}
