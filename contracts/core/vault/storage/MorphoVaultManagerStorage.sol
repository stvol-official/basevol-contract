// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IMetaMorphoV1_1 } from "../../../interfaces/IMetaMorphoV1_1.sol";

library MorphoVaultManagerStorage {
  // keccak256(abi.encode(uint256(keccak256("com.basevol.storage.morphovaultmanager")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 internal constant SLOT =
    0x2e903f9f0e79a6f9916c6b0d4716d39cddd979f46bb58d98751064bda7f81200;

  /// @notice Basis points denominator (100% = 10000)
  uint256 internal constant BPS_DENOMINATOR = 10000;

  /// @notice Maximum number of additional vaults allowed
  uint256 internal constant MAX_ADDITIONAL_VAULTS = 9;

  /// @notice Minimum rebalance threshold in basis points (0.5% = 50 bps)
  uint256 internal constant MIN_REBALANCE_THRESHOLD_BPS = 50;

  /// @notice Allocation info for additional vaults
  /// @dev Primary vault uses existing morphoVault and morphoShares fields
  struct VaultAllocation {
    address vault; // Morpho Vault address
    uint256 weightBps; // Allocation weight in basis points (e.g., 3000 = 30%)
    uint256 shares; // Shares held in this vault
    uint256 deposited; // Total deposited to this vault
    uint256 withdrawn; // Total withdrawn from this vault
    bool isActive; // Whether vault is active
  }

  struct Layout {
    // ============================================
    // EXISTING VARIABLES - DO NOT MODIFY ORDER
    // Slots 0-10 must remain unchanged for upgrade compatibility
    // ============================================

    // Core contracts (slots 0-2)
    IERC20 asset; // slot 0
    IMetaMorphoV1_1 morphoVault; // slot 1 - Primary vault (index 0)
    address strategy; // slot 2
    // Configuration (slots 3-4)
    uint256 maxStrategyDeposit; // slot 3
    uint256 minStrategyDeposit; // slot 4
    // State tracking (slots 5-8)
    uint256 totalDeposited; // slot 5 - Global total deposited
    uint256 totalWithdrawn; // slot 6 - Global total withdrawn
    uint256 totalUtilized; // slot 7 - Global total utilized
    uint256 morphoShares; // slot 8 - Primary vault shares
    // Performance tracking (slots 9-10)
    uint256 lastYieldUpdate; // slot 9
    uint256 accumulatedYield; // slot 10
    // ============================================
    // NEW VARIABLES FOR MULTI-VAULT SUPPORT
    // Added after slot 10 for upgrade compatibility
    // ============================================

    // Multi-vault configuration (slots 11-14)
    VaultAllocation[] additionalVaults; // slot 11 - Additional vaults (index 1+)
    uint256 primaryVaultWeightBps; // slot 12 - Primary vault weight in bps (0 = single mode)
    uint256 rebalanceThresholdBps; // slot 13 - Deviation threshold for rebalance alerts
    bool isMultiVaultEnabled; // slot 14 - Multi-vault mode flag
    // Multi-vault state tracking (slots 15-16)
    uint256 lastRebalanceTimestamp; // slot 15 - Last rebalance time
    uint256 primaryVaultDeposited; // slot 16 - Primary vault deposited (for multi-vault tracking)
  }

  function layout() internal pure returns (Layout storage $) {
    bytes32 slot = SLOT;
    assembly {
      $.slot := slot
    }
  }
}
