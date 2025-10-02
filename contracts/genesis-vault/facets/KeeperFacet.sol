// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibGenesisVaultStorage } from "../libraries/LibGenesisVaultStorage.sol";
import { LibDiamond } from "../../diamond-common/libraries/LibDiamond.sol";

/**
 * @title KeeperFacet
 * @notice Manages keeper addresses for GenesisVault
 * @dev Keepers are authorized to call settlement and auto-processing functions
 */
contract KeeperFacet {
  // ============ Events ============

  event KeeperAdded(address indexed keeper);
  event KeeperRemoved(address indexed keeper);

  // ============ Errors ============

  error InvalidKeeperAddress();
  error KeeperAlreadyExists();
  error KeeperNotFound();
  error OnlyAdmin();

  // ============ Modifiers ============

  modifier onlyAdmin() {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    if (msg.sender != s.admin) revert OnlyAdmin();
    _;
  }

  // ============ Admin Functions ============

  /**
   * @notice Add a keeper address
   * @param keeper The address to add as a keeper
   */
  function addKeeper(address keeper) external onlyAdmin {
    if (keeper == address(0)) revert InvalidKeeperAddress();

    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    // Check if keeper already exists
    for (uint i = 0; i < s.keepers.length; i++) {
      if (s.keepers[i] == keeper) revert KeeperAlreadyExists();
    }

    s.keepers.push(keeper);
    emit KeeperAdded(keeper);
  }

  /**
   * @notice Remove a keeper address
   * @param keeper The address to remove from keepers
   */
  function removeKeeper(address keeper) external onlyAdmin {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    for (uint i = 0; i < s.keepers.length; i++) {
      if (s.keepers[i] == keeper) {
        // Move last element to current position and remove last element
        s.keepers[i] = s.keepers[s.keepers.length - 1];
        s.keepers.pop();
        emit KeeperRemoved(keeper);
        return;
      }
    }

    revert KeeperNotFound();
  }

  // ============ View Functions ============

  /**
   * @notice Get all keeper addresses
   * @return Array of keeper addresses
   */
  function getKeepers() external view returns (address[] memory) {
    return LibGenesisVaultStorage.layout().keepers;
  }

  /**
   * @notice Check if an address is a keeper
   * @param account Address to check
   * @return True if account is a keeper
   */
  function isKeeper(address account) external view returns (bool) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    for (uint i = 0; i < s.keepers.length; i++) {
      if (s.keepers[i] == account) {
        return true;
      }
    }

    return false;
  }
}
