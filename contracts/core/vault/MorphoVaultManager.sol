// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IMetaMorphoV1_1 } from "../../interfaces/IMetaMorphoV1_1.sol";
import { IGenesisStrategy } from "./interfaces/IGenesisStrategy.sol";
import { IMorphoVaultManager } from "./interfaces/IMorphoVaultManager.sol";
import { MorphoVaultManagerStorage } from "./storage/MorphoVaultManagerStorage.sol";
import { LibMorphoMultiVault } from "./libraries/LibMorphoMultiVault.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MorphoVaultManager
/// @author BaseVol Team
/// @notice Manages deposits/withdrawals to Morpho Vaults with multi-vault support
/// @dev Supports both single-vault mode (backward compatible) and multi-vault mode
contract MorphoVaultManager is
  Initializable,
  UUPSUpgradeable,
  PausableUpgradeable,
  OwnableUpgradeable,
  ReentrancyGuardUpgradeable,
  IMorphoVaultManager
{
  using SafeERC20 for IERC20;
  using MorphoVaultManagerStorage for MorphoVaultManagerStorage.Layout;
  using LibMorphoMultiVault for MorphoVaultManagerStorage.Layout;

  /*//////////////////////////////////////////////////////////////
                          LEGACY EVENTS
  //////////////////////////////////////////////////////////////*/

  event DepositedToMorpho(
    address indexed strategy,
    uint256 amount,
    uint256 shares,
    uint256 morphoBalance
  );
  event WithdrawnFromMorpho(
    address indexed strategy,
    uint256 amount,
    uint256 shares,
    uint256 morphoBalance
  );
  event RedeemedFromMorpho(
    address indexed strategy,
    uint256 shares,
    uint256 assets,
    uint256 morphoBalance
  );
  event ConfigUpdated(uint256 maxStrategyDeposit, uint256 minStrategyDeposit);
  event MorphoApprovalGranted(uint256 amount, uint256 timestamp);
  event MorphoApprovalRevoked(uint256 timestamp);
  event EmergencyMorphoApprovalRevoked(address indexed caller, uint256 timestamp);

  /*//////////////////////////////////////////////////////////////
                          LEGACY ERRORS
  //////////////////////////////////////////////////////////////*/

  error InsufficientBalance();
  error InvalidAmount();
  error ExceedsMaxDeposit();
  error BelowMinDeposit();
  error CallerNotAuthorized(address authorized, address caller);
  error DepositFailed();
  error WithdrawFailed();
  error RedeemFailed();
  error InvalidAddress();

  /*//////////////////////////////////////////////////////////////
                            MODIFIERS
  //////////////////////////////////////////////////////////////*/

  modifier authCaller(address authorized) {
    if (_msgSender() != authorized) revert CallerNotAuthorized(authorized, _msgSender());
    _;
  }

  modifier onlyMultiVault() {
    if (!MorphoVaultManagerStorage.layout().isMultiVaultEnabled) revert MultiVaultNotEnabled();
    _;
  }

  /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /*//////////////////////////////////////////////////////////////
                          INITIALIZERS
  //////////////////////////////////////////////////////////////*/

  function initialize(address _morphoVault, address _strategy) external initializer {
    __UUPSUpgradeable_init();
    __Ownable_init(msg.sender);
    __Pausable_init();
    __ReentrancyGuard_init();

    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();

    if (_morphoVault == address(0) || _strategy == address(0)) revert InvalidAddress();

    $.asset = IERC20(IGenesisStrategy(_strategy).asset());
    $.morphoVault = IMetaMorphoV1_1(_morphoVault);
    $.strategy = _strategy;
    $.maxStrategyDeposit = 10000000e6;
    $.minStrategyDeposit = 100e6;
  }

  /// @notice Initializes V2 features (multi-vault support)
  function initializeV2() external reinitializer(2) {
    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();
    $.isMultiVaultEnabled = false;
    $.primaryVaultWeightBps = 0;
    $.rebalanceThresholdBps = 500;
    $.lastRebalanceTimestamp = 0;
    $.primaryVaultDeposited = $.totalDeposited;
  }

  /*//////////////////////////////////////////////////////////////
                      CORE DEPOSIT/WITHDRAW
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IMorphoVaultManager
  function depositToMorpho(
    uint256 amount
  ) external authCaller(strategy()) nonReentrant whenNotPaused {
    if (amount == 0) revert InvalidAmount();

    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();

    if (amount < $.minStrategyDeposit) revert BelowMinDeposit();
    if (amount > $.maxStrategyDeposit) revert ExceedsMaxDeposit();
    if ($.asset.balanceOf(address(this)) < amount) revert InsufficientBalance();

    if (!$.isMultiVaultEnabled) {
      _depositToPrimaryVaultSingle($, amount);
    } else {
      _depositToAllVaults($, amount);
    }
  }

  /// @inheritdoc IMorphoVaultManager
  function withdrawFromMorpho(
    uint256 amount
  ) external authCaller(strategy()) nonReentrant whenNotPaused {
    if (amount == 0) revert InvalidAmount();

    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();

    if (!$.isMultiVaultEnabled) {
      _withdrawFromPrimaryVaultSingle($, amount);
    } else {
      uint256 withdrawn = $.withdrawFromAllVaults(amount);
      _updateWithdrawState($, withdrawn);
      $.asset.safeTransfer($.strategy, withdrawn);
      IGenesisStrategy($.strategy).morphoWithdrawCompletedCallback(withdrawn, true);
    }
  }

  /// @inheritdoc IMorphoVaultManager
  function redeemFromMorpho(
    uint256 shares
  ) external authCaller(strategy()) nonReentrant whenNotPaused {
    if (shares == 0) revert InvalidAmount();

    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();
    if ($.morphoVault.balanceOf(address(this)) < shares) revert InsufficientBalance();

    uint256 assets = $.morphoVault.redeem(shares, address(this), address(this));
    _updateRedeemState($, assets, shares);

    emit RedeemedFromMorpho($.strategy, shares, assets, $.morphoVault.balanceOf(address(this)));

    uint256 transferAmount = Math.min(assets, $.asset.balanceOf(address(this)));
    if (transferAmount > 0) $.asset.safeTransfer($.strategy, transferAmount);

    IGenesisStrategy($.strategy).morphoRedeemCompletedCallback(shares, assets, true);
  }

  /*//////////////////////////////////////////////////////////////
                    MULTI-VAULT ADMIN FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IMorphoVaultManager
  function enableMultiVault(uint256 primaryWeightBps) external onlyOwner {
    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();

    if ($.isMultiVaultEnabled) revert MultiVaultAlreadyEnabled();
    if (primaryWeightBps == 0) revert InvalidWeight(primaryWeightBps);

    $.isMultiVaultEnabled = true;
    $.primaryVaultWeightBps = primaryWeightBps;
    $.primaryVaultDeposited = $.totalDeposited;
    $.lastRebalanceTimestamp = block.timestamp;

    emit MultiVaultEnabled(primaryWeightBps, block.timestamp);
  }

  /// @inheritdoc IMorphoVaultManager
  function disableMultiVault() external onlyOwner onlyMultiVault {
    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();

    for (uint256 i = 0; i < $.additionalVaults.length; i++) {
      if ($.additionalVaults[i].shares > 0) revert InsufficientBalance();
    }

    $.isMultiVaultEnabled = false;
    $.primaryVaultWeightBps = 0;

    emit MultiVaultDisabled(block.timestamp);
  }

  /// @inheritdoc IMorphoVaultManager
  function addVault(address vault, uint256 weightBps) external onlyOwner onlyMultiVault {
    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();

    if (vault == address(0)) revert InvalidAmount();
    if (weightBps == 0) revert InvalidWeight(weightBps);
    if ($.additionalVaults.length >= MorphoVaultManagerStorage.MAX_ADDITIONAL_VAULTS)
      revert MaxVaultsReached(MorphoVaultManagerStorage.MAX_ADDITIONAL_VAULTS + 1);

    if (vault == address($.morphoVault)) revert VaultAlreadyExists(vault);
    for (uint256 i = 0; i < $.additionalVaults.length; i++) {
      if ($.additionalVaults[i].vault == vault) revert VaultAlreadyExists(vault);
    }

    address vaultAsset = IMetaMorphoV1_1(vault).asset();
    if (vaultAsset != address($.asset)) revert AssetMismatch(address($.asset), vaultAsset);

    $.additionalVaults.push(
      MorphoVaultManagerStorage.VaultAllocation({
        vault: vault,
        weightBps: weightBps,
        shares: 0,
        deposited: 0,
        withdrawn: 0,
        isActive: true
      })
    );

    emit VaultAdded($.additionalVaults.length, vault, weightBps, block.timestamp);
  }

  /// @inheritdoc IMorphoVaultManager
  function deactivateVault(uint256 vaultIndex) external onlyOwner onlyMultiVault {
    if (vaultIndex == 0) revert CannotDeactivatePrimaryVault();

    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();
    uint256 idx = vaultIndex - 1;

    if (idx >= $.additionalVaults.length) revert VaultNotFound(vaultIndex);
    if (!$.additionalVaults[idx].isActive) revert VaultAlreadyInactive(vaultIndex);

    $.additionalVaults[idx].isActive = false;

    emit VaultDeactivated(vaultIndex, $.additionalVaults[idx].vault, block.timestamp);
  }

  /// @inheritdoc IMorphoVaultManager
  function reactivateVault(uint256 vaultIndex) external onlyOwner onlyMultiVault {
    if (vaultIndex == 0) revert InvalidAmount();

    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();
    uint256 idx = vaultIndex - 1;

    if (idx >= $.additionalVaults.length) revert VaultNotFound(vaultIndex);
    if ($.additionalVaults[idx].isActive) revert VaultAlreadyActive(vaultIndex);

    $.additionalVaults[idx].isActive = true;

    emit VaultReactivated(vaultIndex, $.additionalVaults[idx].vault, block.timestamp);
  }

  /// @inheritdoc IMorphoVaultManager
  function updateVaultWeight(uint256 vaultIndex, uint256 newWeightBps) external onlyOwner {
    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();

    if (!$.isMultiVaultEnabled) revert MultiVaultNotEnabled();
    if (newWeightBps == 0) revert InvalidWeight(newWeightBps);

    uint256 oldWeight;
    address vaultAddress;

    if (vaultIndex == 0) {
      oldWeight = $.primaryVaultWeightBps;
      vaultAddress = address($.morphoVault);
      $.primaryVaultWeightBps = newWeightBps;
    } else {
      uint256 idx = vaultIndex - 1;
      if (idx >= $.additionalVaults.length) revert VaultNotFound(vaultIndex);

      oldWeight = $.additionalVaults[idx].weightBps;
      vaultAddress = $.additionalVaults[idx].vault;
      $.additionalVaults[idx].weightBps = newWeightBps;
    }

    emit VaultWeightUpdated(vaultIndex, vaultAddress, oldWeight, newWeightBps, block.timestamp);
  }

  /// @inheritdoc IMorphoVaultManager
  function batchUpdateVaultWeights(
    uint256[] calldata vaultIndices,
    uint256[] calldata newWeightsBps
  ) external onlyOwner onlyMultiVault {
    if (vaultIndices.length != newWeightsBps.length) revert InvalidAmount();

    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();

    for (uint256 i = 0; i < vaultIndices.length; i++) {
      uint256 vaultIndex = vaultIndices[i];
      uint256 newWeightBps = newWeightsBps[i];

      if (newWeightBps == 0) revert InvalidWeight(newWeightBps);

      uint256 oldWeight;
      address vaultAddress;

      if (vaultIndex == 0) {
        oldWeight = $.primaryVaultWeightBps;
        vaultAddress = address($.morphoVault);
        $.primaryVaultWeightBps = newWeightBps;
      } else {
        uint256 idx = vaultIndex - 1;
        if (idx >= $.additionalVaults.length) revert VaultNotFound(vaultIndex);

        oldWeight = $.additionalVaults[idx].weightBps;
        vaultAddress = $.additionalVaults[idx].vault;
        $.additionalVaults[idx].weightBps = newWeightBps;
      }

      emit VaultWeightUpdated(vaultIndex, vaultAddress, oldWeight, newWeightBps, block.timestamp);
    }
  }

  /// @inheritdoc IMorphoVaultManager
  function setRebalanceThreshold(uint256 thresholdBps) external onlyOwner {
    if (thresholdBps < MorphoVaultManagerStorage.MIN_REBALANCE_THRESHOLD_BPS)
      revert InvalidRebalanceThreshold(thresholdBps);

    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();
    uint256 oldThreshold = $.rebalanceThresholdBps;
    $.rebalanceThresholdBps = thresholdBps;

    emit RebalanceThresholdUpdated(oldThreshold, thresholdBps);
  }

  /*//////////////////////////////////////////////////////////////
                      REBALANCING FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IMorphoVaultManager
  function rebalance() external onlyOwner onlyMultiVault nonReentrant whenNotPaused {
    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();

    uint256 totalAssets = $.getTotalMorphoAssets();
    uint256 totalWeight = $.getTotalWeightBps();
    if (totalAssets == 0 || totalWeight == 0) revert NothingToRebalance();

    uint256 totalMoved = 0;
    uint256 vaultsAffected = 0;

    uint256 vaultCount = 1 + $.additionalVaults.length;
    uint256[] memory currentAmounts = new uint256[](vaultCount);
    uint256[] memory targetAmounts = new uint256[](vaultCount);

    currentAmounts[0] = $.morphoVault.convertToAssets($.morphoShares);
    targetAmounts[0] = (totalAssets * $.primaryVaultWeightBps) / totalWeight;

    for (uint256 i = 0; i < $.additionalVaults.length; i++) {
      if (!$.additionalVaults[i].isActive) continue;
      currentAmounts[i + 1] = IMetaMorphoV1_1($.additionalVaults[i].vault).convertToAssets(
        $.additionalVaults[i].shares
      );
      targetAmounts[i + 1] = (totalAssets * $.additionalVaults[i].weightBps) / totalWeight;
    }

    // Withdraw from over-allocated
    for (uint256 i = 0; i < vaultCount; i++) {
      if (currentAmounts[i] > targetAmounts[i]) {
        uint256 excess = currentAmounts[i] - targetAmounts[i];
        if (i == 0) {
          $.withdrawFromPrimaryVault(excess);
        } else {
          $.withdrawFromAdditionalVault(i - 1, excess);
        }
        totalMoved += excess;
        vaultsAffected++;
      }
    }

    // Deposit to under-allocated
    uint256 availableBalance = $.asset.balanceOf(address(this));
    for (uint256 i = 0; i < vaultCount; i++) {
      if (currentAmounts[i] < targetAmounts[i]) {
        uint256 deficit = Math.min(targetAmounts[i] - currentAmounts[i], availableBalance);
        if (deficit > 0) {
          if (i == 0) {
            $.depositToPrimaryVault(deficit);
          } else {
            $.depositToAdditionalVault(i - 1, deficit);
          }
          availableBalance -= deficit;
          vaultsAffected++;
        }
      }
    }

    $.lastRebalanceTimestamp = block.timestamp;

    emit Rebalanced(totalMoved, vaultsAffected, block.timestamp);
  }

  /// @inheritdoc IMorphoVaultManager
  function withdrawAllFromVault(
    uint256 vaultIndex
  ) external onlyOwner onlyMultiVault nonReentrant whenNotPaused {
    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();

    if (vaultIndex == 0) {
      uint256 assets = $.morphoVault.convertToAssets($.morphoShares);
      if (assets > 0) $.withdrawFromPrimaryVault(assets);
    } else {
      uint256 idx = vaultIndex - 1;
      if (idx >= $.additionalVaults.length) revert VaultNotFound(vaultIndex);

      if ($.additionalVaults[idx].shares > 0) {
        uint256 assets = IMetaMorphoV1_1($.additionalVaults[idx].vault).convertToAssets(
          $.additionalVaults[idx].shares
        );
        $.withdrawFromAdditionalVault(idx, assets);
      }
    }
  }

  /*//////////////////////////////////////////////////////////////
                      EMERGENCY FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  function emergencyWithdraw(uint256 amount) external onlyOwner nonReentrant {
    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();

    uint256 shares = $.morphoVault.withdraw(amount, owner(), address(this));
    _updateWithdrawStateWithShares($, amount, shares);
    emit WithdrawnFromMorpho($.strategy, amount, shares, $.morphoVault.balanceOf(address(this)));
  }

  function emergencyRevokeMorphoApproval() external onlyOwner {
    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();

    $.asset.approve(address($.morphoVault), 0);
    for (uint256 i = 0; i < $.additionalVaults.length; i++) {
      $.asset.approve($.additionalVaults[i].vault, 0);
    }

    emit EmergencyMorphoApprovalRevoked(msg.sender, block.timestamp);
  }

  function _authorizeUpgrade(address) internal override onlyOwner {}

  /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  function setConfig(uint256 _maxStrategyDeposit, uint256 _minStrategyDeposit) external onlyOwner {
    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();
    $.maxStrategyDeposit = _maxStrategyDeposit;
    $.minStrategyDeposit = _minStrategyDeposit;
    emit ConfigUpdated(_maxStrategyDeposit, _minStrategyDeposit);
  }

  function pause() external onlyOwner {
    _pause();
  }
  function unpause() external onlyOwner {
    _unpause();
  }

  /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  function morphoAssetBalance() public view returns (uint256) {
    return MorphoVaultManagerStorage.layout().getTotalMorphoAssets();
  }

  function morphoShareBalance() public view returns (uint256) {
    return MorphoVaultManagerStorage.layout().morphoVault.balanceOf(address(this));
  }

  function totalDeposited() public view returns (uint256) {
    return MorphoVaultManagerStorage.layout().totalDeposited;
  }
  function totalWithdrawn() public view returns (uint256) {
    return MorphoVaultManagerStorage.layout().totalWithdrawn;
  }
  function totalUtilized() public view returns (uint256) {
    return MorphoVaultManagerStorage.layout().totalUtilized;
  }

  function currentYield() public view returns (uint256 yield) {
    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();
    uint256 currentValue = $.getTotalMorphoAssets();
    uint256 invested = $.totalDeposited > $.totalWithdrawn
      ? $.totalDeposited - $.totalWithdrawn
      : 0;
    if (currentValue > invested) yield = currentValue - invested;
  }

  function config() public view returns (uint256, uint256) {
    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();
    return ($.maxStrategyDeposit, $.minStrategyDeposit);
  }

  function strategy() public view returns (address) {
    return MorphoVaultManagerStorage.layout().strategy;
  }
  function morphoVault() public view returns (address) {
    return address(MorphoVaultManagerStorage.layout().morphoVault);
  }
  function isMultiVaultEnabled() external view returns (bool) {
    return MorphoVaultManagerStorage.layout().isMultiVaultEnabled;
  }
  function getVaultCount() external view returns (uint256) {
    return 1 + MorphoVaultManagerStorage.layout().additionalVaults.length;
  }

  function getActiveVaultCount() external view returns (uint256 count) {
    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();
    count = 1;
    if ($.isMultiVaultEnabled) {
      for (uint256 i = 0; i < $.additionalVaults.length; i++) {
        if ($.additionalVaults[i].isActive) count++;
      }
    }
  }

  function getVaultInfo(uint256 vaultIndex) external view returns (VaultInfo memory) {
    return MorphoVaultManagerStorage.layout().getVaultInfo(vaultIndex);
  }

  function getAllVaultInfos() external view returns (VaultInfo[] memory) {
    return LibMorphoMultiVault.getAllVaultInfos(MorphoVaultManagerStorage.layout());
  }

  function getAllocationStatus() external view returns (AllocationStatus[] memory) {
    return MorphoVaultManagerStorage.layout().getAllocationStatus();
  }

  function isRebalanceNeeded() external view returns (bool needed, uint256 maxDeviationBps) {
    return MorphoVaultManagerStorage.layout().isRebalanceNeeded();
  }

  function getTotalWeightBps() external view returns (uint256) {
    return MorphoVaultManagerStorage.layout().getTotalWeightBps();
  }

  function getRebalanceThreshold() external view returns (uint256) {
    return MorphoVaultManagerStorage.layout().rebalanceThresholdBps;
  }

  function getLastRebalanceTimestamp() external view returns (uint256) {
    return MorphoVaultManagerStorage.layout().lastRebalanceTimestamp;
  }

  function getMorphoAllowance() external view returns (uint256) {
    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();
    return $.asset.allowance(address(this), address($.morphoVault));
  }

  function checkMorphoApprovalHealth()
    external
    view
    returns (bool isHealthy, uint256 currentAllowance)
  {
    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();
    currentAllowance = $.asset.allowance(address(this), address($.morphoVault));
    isHealthy = (currentAllowance == 0);
  }

  /*//////////////////////////////////////////////////////////////
                      INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  function _depositToPrimaryVaultSingle(
    MorphoVaultManagerStorage.Layout storage $,
    uint256 amount
  ) internal {
    $.asset.approve(address($.morphoVault), amount);
    emit MorphoApprovalGranted(amount, block.timestamp);

    uint256 shares = $.morphoVault.deposit(amount, address(this));
    $.asset.approve(address($.morphoVault), 0);
    emit MorphoApprovalRevoked(block.timestamp);

    $.totalDeposited += amount;
    $.totalUtilized += amount;
    $.morphoShares += shares;

    emit DepositedToMorpho($.strategy, amount, shares, $.morphoVault.balanceOf(address(this)));
    IGenesisStrategy($.strategy).morphoDepositCompletedCallback(amount, true);
  }

  function _depositToAllVaults(
    MorphoVaultManagerStorage.Layout storage $,
    uint256 amount
  ) internal {
    LibMorphoMultiVault.depositToAllVaults($, amount);
    $.totalDeposited += amount;
    $.totalUtilized += amount;
    IGenesisStrategy($.strategy).morphoDepositCompletedCallback(amount, true);
  }

  function _withdrawFromPrimaryVaultSingle(
    MorphoVaultManagerStorage.Layout storage $,
    uint256 amount
  ) internal {
    if ($.morphoVault.maxWithdraw(address(this)) < amount) revert InsufficientBalance();

    uint256 shares = $.morphoVault.withdraw(amount, address(this), address(this));
    _updateWithdrawStateWithShares($, amount, shares);

    emit WithdrawnFromMorpho($.strategy, amount, shares, $.morphoVault.balanceOf(address(this)));

    uint256 transferAmount = Math.min(amount, $.asset.balanceOf(address(this)));
    if (transferAmount > 0) $.asset.safeTransfer($.strategy, transferAmount);

    IGenesisStrategy($.strategy).morphoWithdrawCompletedCallback(transferAmount, true);
  }

  function _updateWithdrawState(
    MorphoVaultManagerStorage.Layout storage $,
    uint256 amount
  ) internal {
    if ($.totalUtilized >= amount) {
      $.totalUtilized -= amount;
    } else {
      $.totalUtilized = 0;
    }
    $.totalWithdrawn += amount;
  }

  function _updateWithdrawStateWithShares(
    MorphoVaultManagerStorage.Layout storage $,
    uint256 amount,
    uint256 shares
  ) internal {
    _updateWithdrawState($, amount);
    $.morphoShares -= shares;
  }

  function _updateRedeemState(
    MorphoVaultManagerStorage.Layout storage $,
    uint256 assets,
    uint256 shares
  ) internal {
    _updateWithdrawStateWithShares($, assets, shares);
  }
}
