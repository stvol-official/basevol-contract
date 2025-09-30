// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVaultManager } from "../interfaces/IVaultManager.sol";
import { IClearingHouse } from "../interfaces/IClearingHouse.sol";
import { Round, OneMinOrder, SettlementResult, WithdrawalRequest, Coupon, PriceInfo } from "../types/Types.sol";
import { PythLazer } from "../libraries/PythLazer.sol";

library BaseVolOneMinStorage {
  // keccak256(abi.encode(uint256(keccak256("com.basevol.storage.onemin.secure")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 internal constant SLOT_MAINNET =
    0x8be1692dc372f8902eb9c7cd5d19a5bdd4af3b9d33c637a94997c776bf7c1c00;

  // keccak256(abi.encode(uint256(keccak256("com.basevol.storage.onemin")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 internal constant SLOT_TESTNET =
    0xf47b8291f4eb0ba594d826a8a543e71011d93618498a6b680f32cdb25823c400;

  struct Layout {
    IERC20 token; // Prediction token
    IVaultManager vaultManager;
    IClearingHouse clearingHouse;
    PythLazer pythLazer;
    address adminAddress; // address of the admin
    address[] operatorAddresses; // address of the operator
    mapping(uint256 => uint256) commissionfees; // key: productId, commission rate (e.g. 200 = 2%, 150 = 1.50%)
    mapping(uint256 => mapping(uint256 => uint64)) priceHistory; // timestamp => productId => price
    mapping(uint256 => OneMinOrder) oneMinOrders; // key: order idx
    address vault;
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
