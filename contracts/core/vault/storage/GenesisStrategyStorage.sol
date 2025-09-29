// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IGenesisVault } from "../interfaces/IGenesisVault.sol";
import { IBaseVolManager } from "../interfaces/IBaseVolManager.sol";
import { IMorphoVaultManager } from "../interfaces/IMorphoVaultManager.sol";
import { IClearingHouse } from "../../../interfaces/IClearingHouse.sol";

/// @dev Used to specify strategy's operations.
enum StrategyStatus {
  IDLE, // When new operations are available.
  UTILIZING, // When utilizing assets for BaseVol orders.
  DEUTILIZING, // When deutilizing assets from BaseVol orders.
  REBALANCING, // When rebalancing between Morpho and BaseVol.
  EMERGENCY // When emergency withdraw is needed.
}

library GenesisStrategyStorage {
  // keccak256(abi.encode(uint256(keccak256("com.basevol.storage.genesisstrategy")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 internal constant SLOT =
    0x329793624a430b57825c5c2629f7978ecf9358ac6b0cb51a1483d68edba62100;

  struct Layout {
    IERC20 asset;
    IGenesisVault vault;
    IBaseVolManager baseVolManager;
    IMorphoVaultManager morphoVaultManager;
    IClearingHouse clearingHouse;
    address operator;
    address config;
    StrategyStatus strategyStatus;
    uint256 maxUtilizePct;
    uint256 utilizedAssets;
    uint256 strategyBalance;
    
    // Rebalancing configuration
    uint256 morphoTargetPct; // Target percentage for Morpho (e.g., 90% = 0.9 ether)
    uint256 baseVolTargetPct; // Target percentage for BaseVol (e.g., 10% = 0.1 ether)
    uint256 rebalanceThreshold; // Threshold for triggering rebalancing (e.g., 5% = 0.05 ether)
    
    /* IMPORTANT: you can add new variables here */
  }

  function layout() internal pure returns (Layout storage $) {
    bytes32 slot = SLOT;
    assembly {
      $.slot := slot
    }
  }
}
