// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { VaultInfo, VaultMember } from "../types/Types.sol";
import { IClearingHouse } from "../interfaces/IClearingHouse.sol";

library VaultManagerStorage {
  // keccak256(abi.encode(uint256(keccak256("com.basevol.storage.vault")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 internal constant SLOT =
    0xe94951ea449da5406b0ed180fb989c557b0b8abc4e4c7268f9c7dd3acb05ac00;

  struct Layout {
    IClearingHouse clearingHouse; // Clearing house
    address adminAddress; // Admin address
    mapping(address => bool) operators; // Operators
    mapping(address => mapping(address => VaultInfo)) vaults; // key: product -> vault address
    mapping(address => mapping(address => VaultMember[])) vaultMembers; // key: product -> vault address -> vault members
    address[] operatorList; // List of operators
    mapping(address => address[]) vaultList; // key: product -> vault address
    uint256 vaultCounter; // Add this line
    /* IMPROTANT: you can add new variables here */
  }

  function layout() internal pure returns (Layout storage $) {
    bytes32 slot = SLOT;
    assembly {
      $.slot := slot
    }
  }
}
