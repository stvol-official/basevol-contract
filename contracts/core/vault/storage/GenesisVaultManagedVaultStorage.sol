// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library GenesisVaultManagedVaultStorage {
  // keccak256(abi.encode(uint256(keccak256("com.basevol.storage.genesisvaultmanagedvault")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 internal constant SLOT =
    0xcafa32707f311a92186c31e9dd38c386738c8cc0fbd78d451ab0dd57c3df5c00;

  struct UserPerformanceData {
    /// @dev Weighted Average Entry Price (in share price units, scaled by share decimals precision)
    uint256 waep;
    /// @dev Total shares owned by the user
    uint256 totalShares;
    /// @dev Last epoch when this data was updated
    uint256 lastUpdateEpoch;
  }

  struct ManagementFeeData {
    /// @dev Last timestamp when management fee was charged
    uint256 lastFeeTimestamp;
    /// @dev Total management fees collected (in shares)
    uint256 totalFeesCollected;
  }

  struct Layout {
    // admin
    address admin;
    // management fee
    uint256 managementFee;
    // performance fee
    uint256 performanceFee;
    /// hurdle rate
    uint256 hurdleRate;
    // last timestamp for management fee
    uint256 userDepositLimit;
    // deposit limit in assets for this vault
    uint256 vaultDepositLimit;
    // Entry and exit costs (now fixed amounts)
    uint256 entryCost;
    uint256 exitCost;
    // User-based performance fee tracking
    mapping(address => UserPerformanceData) userPerformanceData;
    // Management fee data
    ManagementFeeData managementFeeData;
    // Fee recipient for all fees (entry, exit, performance)
    address feeRecipient;
    /* IMPROTANT: you can add new variables here */
  }

  function layout() internal pure returns (Layout storage $) {
    bytes32 slot = SLOT;
    assembly {
      $.slot := slot
    }
  }
}
