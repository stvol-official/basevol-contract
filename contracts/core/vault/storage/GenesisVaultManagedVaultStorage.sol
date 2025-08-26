// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library GenesisVaultManagedVaultStorage {
  // keccak256(abi.encode(uint256(keccak256("com.basevol.storage.genesisvaultmanagedvault")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 internal constant SLOT =
    0xcafa32707f311a92186c31e9dd38c386738c8cc0fbd78d451ab0dd57c3df5c00;

  struct Layout {
    address feeRecipient;
    // management fee
    uint256 managementFee;
    // performance fee
    uint256 performanceFee;
    /// hurdle rate
    uint256 hurdleRate;
    // last timestamp for management fee
    uint256 lastAccruedTimestamp;
    // high water mark of totalAssets
    uint256 hwm;
    // last timestamp for performance fee
    uint256 lastHarvestedTimestamp;
    // address of the whitelist provider
    address whitelistProvider;
    // deposit limit in assets for each user
    uint256 userDepositLimit;
    // deposit limit in assets for this vault
    uint256 vaultDepositLimit;
    /* IMPROTANT: you can add new variables here */
  }

  function layout() internal pure returns (Layout storage $) {
    bytes32 slot = SLOT;
    assembly {
      $.slot := slot
    }
  }
}
