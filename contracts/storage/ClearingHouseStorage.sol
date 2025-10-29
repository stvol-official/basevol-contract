// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IVaultManager.sol";
import { WithdrawalRequest, Coupon, ForceWithdrawalRequest, CouponUsageDetail, Product } from "../types/Types.sol";

library ClearingHouseStorage {
  // keccak256(abi.encode(uint256(keccak256("com.basevol.storage.clearinghouse.secure")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 internal constant SLOT_MAINNET =
    0x774c44a0b38ae921c4dec3ca94745bada9f891442f312f232ca295c24066bb00;

  // keccak256(abi.encode(uint256(keccak256("com.basevol.storage.clearinghouse")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 internal constant SLOT_TESTNET =
    0x20427f0c61138b4eb4becfbfceaa6e34fbd8d2897b15f8cd4fe50ddc7b548700;

  struct Layout {
    IERC20 token; // Prediction token
    address adminAddress; // Admin address
    address operatorVaultAddress; // Operator vault address
    mapping(address => bool) operators; // Operators
    mapping(address => uint256) userBalances; // User balances
    uint256 treasuryAmount; // Treasury amount
    WithdrawalRequest[] withdrawalRequests; // Withdrawal requests
    address[] operatorList; // List of operators
    ForceWithdrawalRequest[] forceWithdrawalRequests;
    uint256 forceWithdrawalDelay;
    IVaultManager vaultManager;
    mapping(address => Coupon[]) couponBalances; // user to coupon list
    uint256 couponAmount; // coupon amount
    uint256 usedCouponAmount; // used coupon amount
    address[] couponHolders;
    uint256 withdrawalFee; // withdrawal fee
    mapping(uint256 => bool) processedBatchIds; // processed batch ids
    mapping(address => mapping(uint256 => CouponUsageDetail[])) couponUsageHistory; // user => epoch => CouponUsageDetail[]
    mapping(address => mapping(uint256 => mapping(address => mapping(uint256 => uint256)))) productEscrowBalances; // product => epoch => user => idx => amount
    mapping(address => mapping(uint256 => mapping(address => mapping(uint256 => uint256)))) productEscrowCoupons; // product => epoch => user => idx => amount
    mapping(address => Product) products; // product => Product
    address[] productAddresses; // product addresses
    mapping(address => bool) baseVolManagers; // BaseVol managers
    address[] baseVolManagerList; // List of baseVol managers
    mapping(address => uint256) userEscrowBalances; // user => escrow balance
    address genesisVault; // GenesisVault contract address for asset transfers
    /* IMPROTANT: you can add new variables here */
  }

  function layout() internal view returns (Layout storage $) {
    bytes32 slot = _getSlot();
    assembly {
      $.slot := slot
    }
  }
  function _getSlot() internal view returns (bytes32) {
    uint256 chainId = block.chainid;
    if (chainId == 8453) {
      return SLOT_MAINNET;
    } else if (chainId == 84532) {
      return SLOT_TESTNET;
    } else {
      return SLOT_TESTNET;
    }
  }
}
