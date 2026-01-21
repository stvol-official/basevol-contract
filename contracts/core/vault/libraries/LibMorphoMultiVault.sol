// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IMetaMorphoV1_1 } from "../../../interfaces/IMetaMorphoV1_1.sol";
import { MorphoVaultManagerStorage } from "../storage/MorphoVaultManagerStorage.sol";
import { IMorphoVaultManager } from "../interfaces/IMorphoVaultManager.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LibMorphoMultiVault
/// @notice Library for multi-vault operations in MorphoVaultManager
/// @dev Separates complex logic to reduce main contract size
library LibMorphoMultiVault {
  using SafeERC20 for IERC20;

  /*//////////////////////////////////////////////////////////////
                              EVENTS
  //////////////////////////////////////////////////////////////*/

  event DepositedToVault(
    uint256 indexed vaultIndex,
    address indexed vault,
    uint256 amount,
    uint256 shares,
    uint256 timestamp
  );

  event WithdrawnFromVault(
    uint256 indexed vaultIndex,
    address indexed vault,
    uint256 amount,
    uint256 shares,
    uint256 timestamp
  );

  event MorphoApprovalGranted(uint256 amount, uint256 timestamp);
  event MorphoApprovalRevoked(uint256 timestamp);

  /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Gets total assets across all vaults
  function getTotalMorphoAssets(
    MorphoVaultManagerStorage.Layout storage $
  ) internal view returns (uint256 total) {
    // Primary vault
    total = $.morphoVault.convertToAssets($.morphoShares);

    // Additional vaults (if multi-vault enabled)
    if ($.isMultiVaultEnabled) {
      for (uint256 i = 0; i < $.additionalVaults.length; i++) {
        if (!$.additionalVaults[i].isActive) continue;
        if ($.additionalVaults[i].shares == 0) continue;

        IMetaMorphoV1_1 vault = IMetaMorphoV1_1($.additionalVaults[i].vault);
        total += vault.convertToAssets($.additionalVaults[i].shares);
      }
    }
  }

  /// @notice Gets total weight of all active vaults
  function getTotalWeightBps(
    MorphoVaultManagerStorage.Layout storage $
  ) internal view returns (uint256 total) {
    if (!$.isMultiVaultEnabled) {
      return MorphoVaultManagerStorage.BPS_DENOMINATOR;
    }

    total = $.primaryVaultWeightBps;

    for (uint256 i = 0; i < $.additionalVaults.length; i++) {
      if ($.additionalVaults[i].isActive) {
        total += $.additionalVaults[i].weightBps;
      }
    }
  }

  /// @notice Calculates deviation in basis points
  function calculateDeviationBps(
    uint256 current,
    uint256 target,
    uint256 total
  ) internal pure returns (uint256) {
    if (total == 0) return 0;

    uint256 deviation;
    if (current >= target) {
      deviation = current - target;
    } else {
      deviation = target - current;
    }

    return (deviation * MorphoVaultManagerStorage.BPS_DENOMINATOR) / total;
  }

  /// @notice Gets vault info for a specific index
  function getVaultInfo(
    MorphoVaultManagerStorage.Layout storage $,
    uint256 vaultIndex
  ) internal view returns (IMorphoVaultManager.VaultInfo memory info) {
    if (vaultIndex == 0) {
      // Primary vault
      info.vault = address($.morphoVault);
      info.weightBps = $.isMultiVaultEnabled
        ? $.primaryVaultWeightBps
        : MorphoVaultManagerStorage.BPS_DENOMINATOR;
      info.shares = $.morphoShares;
      info.assetBalance = $.morphoVault.convertToAssets($.morphoShares);
      info.deposited = $.isMultiVaultEnabled ? $.primaryVaultDeposited : $.totalDeposited;
      info.withdrawn = $.totalWithdrawn;
      info.isActive = true;
    } else {
      uint256 additionalIndex = vaultIndex - 1;
      require(additionalIndex < $.additionalVaults.length, "Invalid vault index");

      MorphoVaultManagerStorage.VaultAllocation storage allocation = $.additionalVaults[
        additionalIndex
      ];
      info.vault = allocation.vault;
      info.weightBps = allocation.weightBps;
      info.shares = allocation.shares;
      info.deposited = allocation.deposited;
      info.withdrawn = allocation.withdrawn;
      info.isActive = allocation.isActive;

      if (allocation.isActive && allocation.shares > 0) {
        IMetaMorphoV1_1 vault = IMetaMorphoV1_1(allocation.vault);
        info.assetBalance = vault.convertToAssets(allocation.shares);
      }
    }
  }

  /// @notice Gets allocation status for all vaults
  function getAllocationStatus(
    MorphoVaultManagerStorage.Layout storage $
  ) internal view returns (IMorphoVaultManager.AllocationStatus[] memory statuses) {
    if (!$.isMultiVaultEnabled) {
      statuses = new IMorphoVaultManager.AllocationStatus[](1);
      statuses[0].vaultIndex = 0;
      statuses[0].vault = address($.morphoVault);
      statuses[0].currentBps = MorphoVaultManagerStorage.BPS_DENOMINATOR;
      statuses[0].targetBps = MorphoVaultManagerStorage.BPS_DENOMINATOR;
      statuses[0].deviationBps = 0;
      statuses[0].currentAssets = $.morphoVault.convertToAssets($.morphoShares);
      statuses[0].targetAssets = statuses[0].currentAssets;
      return statuses;
    }

    uint256 totalAssets = getTotalMorphoAssets($);
    uint256 totalWeight = getTotalWeightBps($);
    uint256 count = 1 + $.additionalVaults.length;

    statuses = new IMorphoVaultManager.AllocationStatus[](count);

    // Primary vault
    uint256 primaryAssets = $.morphoVault.convertToAssets($.morphoShares);
    statuses[0].vaultIndex = 0;
    statuses[0].vault = address($.morphoVault);
    statuses[0].currentBps = totalAssets > 0
      ? (primaryAssets * MorphoVaultManagerStorage.BPS_DENOMINATOR) / totalAssets
      : 0;
    statuses[0].targetBps = totalWeight > 0
      ? ($.primaryVaultWeightBps * MorphoVaultManagerStorage.BPS_DENOMINATOR) / totalWeight
      : 0;
    statuses[0].deviationBps = int256(statuses[0].currentBps) - int256(statuses[0].targetBps);
    statuses[0].currentAssets = primaryAssets;
    statuses[0].targetAssets = totalWeight > 0
      ? (totalAssets * $.primaryVaultWeightBps) / totalWeight
      : 0;

    // Additional vaults
    for (uint256 i = 0; i < $.additionalVaults.length; i++) {
      MorphoVaultManagerStorage.VaultAllocation storage allocation = $.additionalVaults[i];

      uint256 vaultAssets = 0;
      if (allocation.isActive && allocation.shares > 0) {
        IMetaMorphoV1_1 vault = IMetaMorphoV1_1(allocation.vault);
        vaultAssets = vault.convertToAssets(allocation.shares);
      }

      statuses[i + 1].vaultIndex = i + 1;
      statuses[i + 1].vault = allocation.vault;
      statuses[i + 1].currentBps = totalAssets > 0
        ? (vaultAssets * MorphoVaultManagerStorage.BPS_DENOMINATOR) / totalAssets
        : 0;
      statuses[i + 1].targetBps = (totalWeight > 0 && allocation.isActive)
        ? (allocation.weightBps * MorphoVaultManagerStorage.BPS_DENOMINATOR) / totalWeight
        : 0;
      statuses[i + 1].deviationBps =
        int256(statuses[i + 1].currentBps) -
        int256(statuses[i + 1].targetBps);
      statuses[i + 1].currentAssets = vaultAssets;
      statuses[i + 1].targetAssets = (totalWeight > 0 && allocation.isActive)
        ? (totalAssets * allocation.weightBps) / totalWeight
        : 0;
    }
  }

  /// @notice Gets all vault infos
  function getAllVaultInfos(
    MorphoVaultManagerStorage.Layout storage $
  ) internal view returns (IMorphoVaultManager.VaultInfo[] memory infos) {
    uint256 count = 1 + $.additionalVaults.length;
    infos = new IMorphoVaultManager.VaultInfo[](count);
    for (uint256 i = 0; i < count; i++) {
      infos[i] = getVaultInfo($, i);
    }
  }

  /// @notice Checks if rebalance is needed
  function isRebalanceNeeded(
    MorphoVaultManagerStorage.Layout storage $
  ) internal view returns (bool needed, uint256 maxDeviationBps) {
    if (!$.isMultiVaultEnabled) return (false, 0);

    uint256 totalAssets = getTotalMorphoAssets($);
    if (totalAssets == 0) return (false, 0);

    uint256 totalWeight = getTotalWeightBps($);
    if (totalWeight == 0) return (false, 0);

    // Check primary vault
    uint256 primaryAssets = $.morphoVault.convertToAssets($.morphoShares);
    uint256 primaryTarget = (totalAssets * $.primaryVaultWeightBps) / totalWeight;
    uint256 primaryDeviation = calculateDeviationBps(primaryAssets, primaryTarget, totalAssets);
    if (primaryDeviation > maxDeviationBps) {
      maxDeviationBps = primaryDeviation;
    }

    // Check additional vaults
    for (uint256 i = 0; i < $.additionalVaults.length; i++) {
      if (!$.additionalVaults[i].isActive) continue;

      IMetaMorphoV1_1 vault = IMetaMorphoV1_1($.additionalVaults[i].vault);
      uint256 vaultAssets = vault.convertToAssets($.additionalVaults[i].shares);
      uint256 vaultTarget = (totalAssets * $.additionalVaults[i].weightBps) / totalWeight;
      uint256 vaultDeviation = calculateDeviationBps(vaultAssets, vaultTarget, totalAssets);

      if (vaultDeviation > maxDeviationBps) {
        maxDeviationBps = vaultDeviation;
      }
    }

    needed = maxDeviationBps > $.rebalanceThresholdBps;
  }

  /*//////////////////////////////////////////////////////////////
                        DEPOSIT FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Deposits to primary vault and returns shares
  function depositToPrimaryVault(
    MorphoVaultManagerStorage.Layout storage $,
    uint256 amount
  ) internal returns (uint256 shares) {
    $.asset.approve(address($.morphoVault), amount);
    emit MorphoApprovalGranted(amount, block.timestamp);

    shares = $.morphoVault.deposit(amount, address(this));

    $.asset.approve(address($.morphoVault), 0);
    emit MorphoApprovalRevoked(block.timestamp);

    $.morphoShares += shares;
    $.primaryVaultDeposited += amount;

    emit DepositedToVault(0, address($.morphoVault), amount, shares, block.timestamp);
  }

  /// @notice Deposits to an additional vault
  function depositToAdditionalVault(
    MorphoVaultManagerStorage.Layout storage $,
    uint256 additionalIndex,
    uint256 amount
  ) internal returns (uint256 shares) {
    MorphoVaultManagerStorage.VaultAllocation storage allocation = $.additionalVaults[
      additionalIndex
    ];
    IMetaMorphoV1_1 vault = IMetaMorphoV1_1(allocation.vault);

    $.asset.approve(allocation.vault, amount);
    emit MorphoApprovalGranted(amount, block.timestamp);

    shares = vault.deposit(amount, address(this));

    $.asset.approve(allocation.vault, 0);
    emit MorphoApprovalRevoked(block.timestamp);

    allocation.shares += shares;
    allocation.deposited += amount;

    emit DepositedToVault(additionalIndex + 1, allocation.vault, amount, shares, block.timestamp);
  }

  /*//////////////////////////////////////////////////////////////
                        WITHDRAW FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Withdraws from primary vault
  function withdrawFromPrimaryVault(
    MorphoVaultManagerStorage.Layout storage $,
    uint256 amount
  ) internal returns (uint256 shares) {
    shares = $.morphoVault.withdraw(amount, address(this), address(this));
    $.morphoShares -= shares;

    emit WithdrawnFromVault(0, address($.morphoVault), amount, shares, block.timestamp);
  }

  /// @notice Withdraws from an additional vault
  function withdrawFromAdditionalVault(
    MorphoVaultManagerStorage.Layout storage $,
    uint256 additionalIndex,
    uint256 amount
  ) internal returns (uint256 shares) {
    MorphoVaultManagerStorage.VaultAllocation storage allocation = $.additionalVaults[
      additionalIndex
    ];
    IMetaMorphoV1_1 vault = IMetaMorphoV1_1(allocation.vault);

    shares = vault.withdraw(amount, address(this), address(this));
    allocation.shares -= shares;
    allocation.withdrawn += amount;

    emit WithdrawnFromVault(additionalIndex + 1, allocation.vault, amount, shares, block.timestamp);
  }

  /// @notice Withdraws proportionally from all vaults
  function withdrawFromAllVaults(
    MorphoVaultManagerStorage.Layout storage $,
    uint256 amount
  ) internal returns (uint256 totalWithdrawnAmount) {
    uint256 totalAssets = getTotalMorphoAssets($);
    require(totalAssets >= amount, "Insufficient balance");

    // Withdraw from primary vault proportionally
    uint256 primaryAssets = $.morphoVault.convertToAssets($.morphoShares);
    if (primaryAssets > 0) {
      uint256 primaryWithdrawAmount = Math.min(
        (amount * primaryAssets) / totalAssets,
        $.morphoVault.maxWithdraw(address(this))
      );

      if (primaryWithdrawAmount > 0) {
        withdrawFromPrimaryVault($, primaryWithdrawAmount);
        totalWithdrawnAmount += primaryWithdrawAmount;
      }
    }

    // Withdraw from additional vaults proportionally
    for (uint256 i = 0; i < $.additionalVaults.length; i++) {
      MorphoVaultManagerStorage.VaultAllocation storage allocation = $.additionalVaults[i];
      if (!allocation.isActive || allocation.shares == 0) continue;

      IMetaMorphoV1_1 vault = IMetaMorphoV1_1(allocation.vault);
      uint256 vaultAssets = vault.convertToAssets(allocation.shares);

      uint256 vaultWithdrawAmount = Math.min(
        (amount * vaultAssets) / totalAssets,
        vault.maxWithdraw(address(this))
      );

      if (vaultWithdrawAmount > 0) {
        withdrawFromAdditionalVault($, i, vaultWithdrawAmount);
        totalWithdrawnAmount += vaultWithdrawAmount;
      }
    }
  }

  /// @notice Deposits to all vaults according to weights
  function depositToAllVaults(
    MorphoVaultManagerStorage.Layout storage $,
    uint256 amount
  ) internal {
    uint256 totalWeight = getTotalWeightBps($);
    if (totalWeight == 0) {
      depositToPrimaryVault($, amount);
      return;
    }

    uint256 remainingAmount = amount;
    uint256 activeAdditionalCount = 0;
    for (uint256 i = 0; i < $.additionalVaults.length; i++) {
      if ($.additionalVaults[i].isActive) activeAdditionalCount++;
    }

    uint256 primaryAmount = (amount * $.primaryVaultWeightBps) / totalWeight;
    if (primaryAmount > 0) {
      depositToPrimaryVault($, primaryAmount);
      remainingAmount -= primaryAmount;
    }

    uint256 processedCount = 0;
    for (uint256 i = 0; i < $.additionalVaults.length; i++) {
      if (!$.additionalVaults[i].isActive) continue;

      processedCount++;
      uint256 vaultAmount;

      if (processedCount == activeAdditionalCount) {
        vaultAmount = remainingAmount;
      } else {
        vaultAmount = (amount * $.additionalVaults[i].weightBps) / totalWeight;
        remainingAmount -= vaultAmount;
      }

      if (vaultAmount > 0) {
        depositToAdditionalVault($, i, vaultAmount);
      }
    }
  }
}
