// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IClearingHouse } from "../../../interfaces/IClearingHouse.sol";

struct AssetAllocation {
  uint256 totalAllocated;
  uint256 totalUtilized;
  uint256 availableForWithdrawal;
}

library BaseVolManagerStorage {
  // keccak256(abi.encode(uint256(keccak256("com.basevol.storage.basevolmanager")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 internal constant SLOT =
    0x369ecbdecd065cdac406d7a3641d3f9ba8a5d4bd5217482a7efe535b0f42af00;

  struct Layout {
    // Core contracts
    IERC20 asset;
    IClearingHouse clearingHouse;
    address strategy;
    // Configuration
    uint256 maxStrategyDeposit;
    uint256 minStrategyDeposit;
    uint256 maxTotalExposure;
    // State tracking
    uint256 totalDeposited;
    uint256 totalWithdrawn;
    uint256 totalUtilized;
    address[] activeStrategies;
    uint256 activeStrategyCount;
    // Asset allocation
    AssetAllocation assetAllocation;
  }

  function layout() internal pure returns (Layout storage $) {
    bytes32 slot = SLOT;
    assembly {
      $.slot := slot
    }
  }
}
