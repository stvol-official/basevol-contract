// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IMetaMorphoV1_1 } from "../../../interfaces/IMetaMorphoV1_1.sol";

library MorphoVaultManagerStorage {
  // keccak256(abi.encode(uint256(keccak256("com.basevol.storage.morphovaultmanager")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 internal constant SLOT =
    0x2e903f9f0e79a6f9916c6b0d4716d39cddd979f46bb58d98751064bda7f81200;

  struct Layout {
    // Core contracts
    IERC20 asset;
    IMetaMorphoV1_1 morphoVault;
    address strategy;
    // Configuration
    uint256 maxStrategyDeposit;
    uint256 minStrategyDeposit;
    // State tracking
    uint256 totalDeposited;
    uint256 totalWithdrawn;
    uint256 totalUtilized;
    uint256 morphoShares; // Track Morpho shares owned
    // Performance tracking
    uint256 lastYieldUpdate;
    uint256 accumulatedYield;

    /* IMPORTANT: you can add new variables here */
  }

  function layout() internal pure returns (Layout storage $) {
    bytes32 slot = SLOT;
    assembly {
      $.slot := slot
    }
  }
}
