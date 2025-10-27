// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { IGenesisVault } from "./interfaces/IGenesisVault.sol";
import { IBaseVolManager } from "./interfaces/IBaseVolManager.sol";
import { IMorphoVaultManager } from "./interfaces/IMorphoVaultManager.sol";
import { IClearingHouse } from "../../interfaces/IClearingHouse.sol";
import { GenesisStrategyStorage, StrategyStatus } from "./storage/GenesisStrategyStorage.sol";
import { IGenesisStrategyErrors } from "./errors/GenesisStrategyErrors.sol";

contract GenesisStrategy is
  Initializable,
  UUPSUpgradeable,
  PausableUpgradeable,
  OwnableUpgradeable,
  ReentrancyGuardUpgradeable,
  IGenesisStrategyErrors
{
  using Math for uint256;
  using SafeERC20 for IERC20;
  using SafeCast for uint256;
  using Strings for uint256;

  uint256 internal constant FLOAT_PRECISION = 1e18;

  event BaseVolUtilize(address indexed caller, uint256 amount);
  event BaseVolDeutilize(address indexed caller, uint256 amount);
  event BaseVolManagerUpdated(address indexed account, address indexed newBaseVolManager);
  event MorphoVaultManagerUpdated(address indexed account, address indexed newMorphoVaultManager);
  event ClearingHouseUpdated(address indexed account, address indexed newClearingHouse);
  event OperatorUpdated(address indexed account, address indexed newOperator);
  event KeeperAction(string action, uint256 amount);

  // Morpho related events
  event MorphoUtilize(address indexed caller, uint256 amount);
  event MorphoDeutilize(address indexed caller, uint256 amount);
  event TargetAllocationsUpdated(uint256 morphoPct, uint256 baseVolPct);
  event RebalancingCompleted(
    uint256 morphoAssets,
    uint256 baseVolAssets,
    uint256 targetMorpho,
    uint256 targetBaseVol
  );

  event Stopped(address indexed account);
  event LossDetected(uint256 lossAmount, uint256 lossPercentage, string severity);
  event StrategyBalanceReset(
    uint256 oldStrategyBalance,
    uint256 newStrategyBalance,
    uint256 oldBaseVolBalance,
    uint256 newBaseVolBalance,
    uint256 oldMorphoBalance,
    uint256 newMorphoBalance
  );

  event DebugLog(string message);

  /// @dev Authorize caller if it is authorized one.
  modifier authCaller(address authorized) {
    if (_msgSender() != authorized) {
      revert CallerNotAuthorized(authorized, _msgSender());
    }
    _;
  }

  /// @dev Authorize caller if it is owner and vault.
  modifier onlyOwnerOrVault() {
    if (_msgSender() != owner() && _msgSender() != vault()) {
      revert CallerNotOwnerOrVault();
    }
    _;
  }

  /// @dev Validates if strategy is in IDLE status, otherwise reverts calling.
  modifier whenIdle() {
    _validateStrategyStatus(StrategyStatus.IDLE);
    _;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }
  function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

  function initialize(
    address _vault,
    address _clearingHouse,
    address _operator
  ) external initializer {
    __UUPSUpgradeable_init();
    __Ownable_init(_msgSender());
    __Pausable_init();
    __ReentrancyGuard_init();

    require(_vault != address(0), "Invalid vault address");
    require(_clearingHouse != address(0), "Invalid ClearingHouse address");
    require(_operator != address(0), "Invalid operator address");

    address _asset = IGenesisVault(_vault).asset();
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();

    $.asset = IERC20(_asset);
    $.vault = IGenesisVault(_vault);
    $.clearingHouse = IClearingHouse(_clearingHouse);
    $.operator = _operator;

    // Set default target allocations: 90% Morpho, 10% BaseVol
    $.morphoTargetPct = 0.9 ether; // 90%
    $.baseVolTargetPct = 0.1 ether; // 10%
    $.rebalanceThreshold = 0.05 ether; // 5% threshold
  }

  /// @notice Callback function called by BaseVolManager after deposit completion
  /// @dev Only callable by BaseVolManager
  /// @param amount The amount that was deposited
  /// @param success Whether the deposit was successful
  function baseVolDepositCompletedCallback(
    uint256 amount,
    bool success
  ) external authCaller(baseVolManager()) {
    if (success) {
      // Update strategy state
      GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
      $.strategyBalance += amount;
      $.baseVolInitialBalance += amount; // Track for profit/loss calculation
      emit BaseVolUtilize(_msgSender(), amount);
    }

    if (success) {
      _setStrategyStatus(StrategyStatus.IDLE);
    } else {
      // TODO: handle failed utilize
      emit DebugLog("Utilize operation failed");
    }
  }

  /// @notice Withdraws all assets from BaseVol and Morpho and transfers them to Vault
  /// @dev Called when stop() is invoked to retrieve all deployed assets
  /// @dev Withdraws from both BaseVol (ClearingHouse) and Morpho Vault
  /// @dev All assets (including idle) are transferred to Vault via callbacks
  function _deutilize() internal whenIdle {
    _setStrategyStatus(StrategyStatus.DEUTILIZING);

    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();

    // 1. Withdraw all assets from BaseVol (ClearingHouse)
    // Assets will be transferred to Vault in baseVolWithdrawCompletedCallback
    uint256 baseVolBalance = $.baseVolManager.totalClearingHouseBalance();
    if (baseVolBalance > 0) {
      $.baseVolManager.withdrawFromClearingHouse(baseVolBalance);
    }

    // 2. Withdraw all assets from Morpho Vault (if configured)
    // Assets will be transferred to Vault in morphoWithdrawCompletedCallback
    if (address($.morphoVaultManager) != address(0)) {
      uint256 morphoBalance = getMorphoAssets();
      if (morphoBalance > 0) {
        $.morphoVaultManager.withdrawFromMorpho(morphoBalance);
      }
    }

    // 3. Transfer any existing idle assets to Vault immediately
    uint256 idleBalance = getStrategyIdleAssets();
    if (idleBalance > 0) {
      IERC20(asset()).safeTransfer(address($.vault), idleBalance);
      emit DebugLog(
        string(abi.encodePacked("Transferred ", idleBalance.toString(), " idle assets to vault"))
      );
    }

    // 4. If no async withdrawals are pending, set status to IDLE
    if (
      baseVolBalance == 0 && (address($.morphoVaultManager) == address(0) || getMorphoAssets() == 0)
    ) {
      _setStrategyStatus(StrategyStatus.IDLE);
    }
  }

  /*//////////////////////////////////////////////////////////////
                            KEEPER LOGIC   
    //////////////////////////////////////////////////////////////*/

  /// @notice Keeper-only rebalancing function - rebalances all assets to target allocation
  /// @dev Only callable by Operator and can only be executed in IDLE state
  /// @dev Called after round settlement to rebalance all assets including idle assets
  /// @dev If Morpho is configured: 10% BaseVol, 90% Morpho
  /// @dev If Morpho is NOT configured: 10% BaseVol, 90% idle (waiting for Morpho)
  function keeperRebalance() external authCaller(operator()) nonReentrant {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    IGenesisVault _vault = $.vault;

    // First, transfer all vault idle assets to strategy
    uint256 vaultIdleAssets = _vault.idleAssets();
    if (vaultIdleAssets > 0) {
      IERC20 _asset = $.asset;
      _asset.safeTransferFrom(address(_vault), address(this), vaultIdleAssets);
      emit DebugLog(
        string(
          abi.encodePacked(
            "Transferred ",
            vaultIdleAssets.toString(),
            " idle assets from vault to strategy"
          )
        )
      );
    }

    // Get current total assets under management
    uint256 currentBaseVol = getBaseVolAssets();
    uint256 currentMorpho = getMorphoAssets();
    uint256 idleAssets = getStrategyIdleAssets();

    // Calculate total assets including idle
    uint256 totalAssets = currentBaseVol + currentMorpho + idleAssets;

    if (totalAssets == 0) {
      emit KeeperAction("NO_ASSETS_TO_REBALANCE", 0);
      return;
    }

    // Calculate target allocations (10% BaseVol, 90% Morpho/idle)
    uint256 targetBaseVol = totalAssets.mulDiv($.baseVolTargetPct, FLOAT_PRECISION);
    uint256 targetMorpho = totalAssets - targetBaseVol;

    bool morphoConfigured = address($.morphoVaultManager) != address(0);

    emit DebugLog(
      string(
        abi.encodePacked(
          "Rebalancing: Total=",
          totalAssets.toString(),
          " Idle=",
          idleAssets.toString(),
          " CurrentBV=",
          currentBaseVol.toString(),
          " CurrentM=",
          currentMorpho.toString(),
          " TargetBV=",
          targetBaseVol.toString(),
          " TargetM=",
          targetMorpho.toString(),
          " MorphoConfigured=",
          morphoConfigured ? "true" : "false"
        )
      )
    );

    // Execute rebalancing
    _executeRebalancing(
      currentBaseVol,
      currentMorpho,
      targetBaseVol,
      targetMorpho,
      idleAssets,
      morphoConfigured
    );

    emit KeeperAction("REBALANCE_COMPLETED", totalAssets);
  }

  /// @notice Processes idle assets for the withdraw requests.
  /// @dev Callable by anyone and only when strategy is in the IDLE status.
  function processAssetsToWithdraw() public whenIdle {
    address _asset = asset();
    uint256 _assetsToWithdraw = getStrategyIdleAssets();

    if (_assetsToWithdraw > 0) {
      IERC20(_asset).safeTransfer(vault(), _assetsToWithdraw);
    }
  }

  /// @notice Withdraws all strategy assets (BaseVol, Morpho, and idle) to vault for round settlement accounting
  /// @dev Only callable by vault during settlement for clean per-round accounting
  /// @dev Withdraws all assets from BaseVol, Morpho, and transfers idle assets to vault
  function withdrawAllStrategyAssetsForSettlement() external authCaller(vault()) nonReentrant {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();

    // Mark as settlement withdrawal
    _setStrategyStatus(StrategyStatus.DEUTILIZING);
    $.isSettlementWithdrawal = true;

    bool hasWithdrawals = false;

    // 1. Withdraw all withdrawable BaseVol assets (excludes escrowed funds)
    uint256 baseVolAmount = getWithdrawableBaseVolAssets();
    if (baseVolAmount > 0) {
      $.baseVolManager.withdrawFromClearingHouse(baseVolAmount);
      hasWithdrawals = true;
      emit DebugLog(
        string(abi.encodePacked("Withdrawing BaseVol for settlement: ", baseVolAmount.toString()))
      );
    }

    // 2. Withdraw all Morpho assets (if configured)
    if (address($.morphoVaultManager) != address(0)) {
      uint256 morphoAmount = getMorphoAssets();
      if (morphoAmount > 0) {
        $.morphoVaultManager.withdrawFromMorpho(morphoAmount);
        hasWithdrawals = true;
        emit DebugLog(
          string(abi.encodePacked("Withdrawing Morpho for settlement: ", morphoAmount.toString()))
        );
      }
    }

    // 3. Transfer idle assets to vault immediately
    uint256 idleAmount = getStrategyIdleAssets();
    if (idleAmount > 0) {
      // Double-check actual balance before transfer
      uint256 actualBalance = IERC20(asset()).balanceOf(address(this));
      uint256 transferAmount = idleAmount > actualBalance ? actualBalance : idleAmount;

      if (transferAmount < idleAmount) {
        emit DebugLog(
          string(
            abi.encodePacked(
              "Warning: Strategy idle balance mismatch. Expected: ",
              idleAmount.toString(),
              ", Actual: ",
              actualBalance.toString()
            )
          )
        );
      }

      if (transferAmount > 0) {
        IERC20(asset()).safeTransfer(address($.vault), transferAmount);
        emit DebugLog(
          string(
            abi.encodePacked(
              "Transferring idle assets to vault for settlement: ",
              transferAmount.toString()
            )
          )
        );
      }
    }

    // If no async withdrawals are pending, reset status
    if (!hasWithdrawals) {
      $.isSettlementWithdrawal = false;
      _setStrategyStatus(StrategyStatus.IDLE);
      emit DebugLog("No strategy assets to withdraw for settlement");
    }
  }

  /// @notice Provides liquidity for vault withdrawal requests by intelligently sourcing from available assets
  /// @dev Only callable by vault. Attempts to fulfill request from: 1) idle assets, 2) BaseVol, 3) Morpho
  /// @param amountNeeded The amount of liquidity needed by the vault
  function provideLiquidityForWithdrawals(
    uint256 amountNeeded
  ) external authCaller(vault()) whenIdle nonReentrant {
    if (amountNeeded == 0) return;

    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    uint256 remaining = amountNeeded;

    // Step 1: Use idle assets first (most liquid)
    uint256 idleBalance = getStrategyIdleAssets();
    if (remaining > 0 && idleBalance > 0) {
      uint256 fromIdle = Math.min(remaining, idleBalance);
      IERC20(asset()).safeTransfer(vault(), fromIdle);
      remaining -= fromIdle;
      emit DebugLog(string(abi.encodePacked("Provided from idle: ", fromIdle.toString())));
    }

    // If fully satisfied from idle assets, we're done
    if (remaining == 0) {
      emit DebugLog("Withdrawal request fully satisfied from idle assets");
      return;
    }

    // Store the total remaining amount that needs to be fulfilled
    $.pendingWithdrawAmount = remaining;

    // Step 2: Check what's available from both sources
    uint256 baseVolAvailable = 0;
    uint256 morphoAvailable = 0;

    if (address($.baseVolManager) != address(0)) {
      baseVolAvailable = getWithdrawableBaseVolAssets();
    }

    if (address($.morphoVaultManager) != address(0)) {
      morphoAvailable = getMorphoAssets();
    }

    // Start with BaseVol if available (higher liquidity)
    if (baseVolAvailable > 0) {
      uint256 fromBaseVol = Math.min(remaining, baseVolAvailable);

      _setStrategyStatus(StrategyStatus.DEUTILIZING);
      $.baseVolManager.withdrawFromClearingHouse(fromBaseVol);

      emit DebugLog(
        string(
          abi.encodePacked(
            "Requesting from BaseVol: ",
            fromBaseVol.toString(),
            " (total needed: ",
            remaining.toString(),
            ", morpho available: ",
            morphoAvailable.toString(),
            ")"
          )
        )
      );

      // Callback will handle continuing to Morpho if needed
      return;
    } else if (morphoAvailable > 0) {
      // Only Morpho available, go directly there
      uint256 fromMorpho = Math.min(remaining, morphoAvailable);

      _setStrategyStatus(StrategyStatus.DEUTILIZING);
      $.morphoVaultManager.withdrawFromMorpho(fromMorpho);

      emit DebugLog(string(abi.encodePacked("Requesting from Morpho: ", fromMorpho.toString())));
      return;
    } else {
      // No additional assets available
      $.pendingWithdrawAmount = 0; // Clear since we can't fulfill
      emit DebugLog(
        string(abi.encodePacked("Could not fulfill remaining: ", remaining.toString()))
      );
    }
  }

  /// @notice Sets the BaseVolManager.
  function setBaseVolManager(address newBaseVolManager) external onlyOwner {
    if (baseVolManager() != newBaseVolManager) {
      require(newBaseVolManager != address(0), "Invalid address");
      GenesisStrategyStorage.layout().baseVolManager = IBaseVolManager(newBaseVolManager);
      emit BaseVolManagerUpdated(_msgSender(), newBaseVolManager);
    }
  }

  /// @notice Sets the MorphoVaultManager.
  function setMorphoVaultManager(address newMorphoVaultManager) external onlyOwner {
    if (morphoVaultManager() != newMorphoVaultManager) {
      require(newMorphoVaultManager != address(0), "Invalid address");
      GenesisStrategyStorage.layout().morphoVaultManager = IMorphoVaultManager(
        newMorphoVaultManager
      );
      emit MorphoVaultManagerUpdated(_msgSender(), newMorphoVaultManager);
    }
  }

  /// @notice Sets the ClearingHouse.
  function setClearingHouse(address newClearingHouse) external onlyOwner {
    if (clearingHouse() != newClearingHouse) {
      require(newClearingHouse != address(0), "Invalid address");
      GenesisStrategyStorage.layout().clearingHouse = IClearingHouse(newClearingHouse);
      emit ClearingHouseUpdated(_msgSender(), newClearingHouse);
    }
  }

  /// @notice Sets the operator.
  function setOperator(address newOperator) external onlyOwner {
    _setOperator(newOperator);
  }

  /// @notice Sets target allocation percentages for Morpho and BaseVol
  function setTargetAllocations(uint256 _morphoPct, uint256 _baseVolPct) external onlyOwner {
    require(_morphoPct + _baseVolPct == FLOAT_PRECISION, "Invalid percentages");
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    $.morphoTargetPct = _morphoPct;
    $.baseVolTargetPct = _baseVolPct;
    emit TargetAllocationsUpdated(_morphoPct, _baseVolPct);
  }

  /// @notice Sets the rebalancing threshold
  function setRebalanceThreshold(uint256 _threshold) external onlyOwner {
    require(_threshold <= 0.2 ether, "Threshold too high"); // Max 20%
    GenesisStrategyStorage.layout().rebalanceThreshold = _threshold;
  }

  /// @notice Pauses strategy, disabling utilizing and deutilizing for withdraw requests.
  function pause() external onlyOwnerOrVault whenNotPaused {
    _pause();
  }

  /// @notice Unpauses strategy.
  function unpause() external onlyOwnerOrVault whenPaused {
    _unpause();
  }

  /// @notice Stops strategy while processing all assets back to vault.
  function stop() external onlyOwnerOrVault whenNotPaused {
    _setStrategyStatus(StrategyStatus.DEUTILIZING);
    _deutilize();

    _pause();
    emit Stopped(_msgSender());
  }

  /// @notice Get current PnL information for the entire strategy (BaseVol + Morpho)
  /// @dev Calculates both realized and unrealized profit/loss
  /// @dev PnL = (current real-time balance) - (initial capital)
  /// @return isProfit Whether the strategy is in profit
  /// @return absolutePnL Absolute PnL amount (positive for profit, negative for loss)
  /// @return percentagePnL PnL as percentage of initial capital (0 if initial capital is 0)
  /// @return currentBalance Current total balance (real-time)
  /// @return initialStrategyBalance Initial capital (updated on withdrawals)
  function getPnLInfo()
    external
    view
    returns (
      bool isProfit,
      int256 absolutePnL,
      uint256 percentagePnL,
      uint256 currentBalance,
      uint256 initialStrategyBalance
    )
  {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    currentBalance = getTotalUtilizedAssets();
    initialStrategyBalance = $.strategyBalance;

    if (currentBalance > initialStrategyBalance) {
      isProfit = true;
      absolutePnL = int256(currentBalance - initialStrategyBalance);
      // Prevent division by zero
      if (initialStrategyBalance > 0) {
        percentagePnL =
          ((currentBalance - initialStrategyBalance) * FLOAT_PRECISION) /
          initialStrategyBalance;
      } else {
        percentagePnL = 0;
      }
    } else if (currentBalance < initialStrategyBalance) {
      isProfit = false;
      absolutePnL = -int256(initialStrategyBalance - currentBalance);
      // Prevent division by zero
      if (initialStrategyBalance > 0) {
        percentagePnL =
          ((initialStrategyBalance - currentBalance) * FLOAT_PRECISION) /
          initialStrategyBalance;
      } else {
        percentagePnL = 0;
      }
    } else {
      isProfit = false;
      absolutePnL = 0;
      percentagePnL = 0;
    }
  }

  /// @notice Get current profit amount for entire strategy (0 if in loss)
  /// @return profitAmount Current profit amount
  function getCurrentProfit() external view returns (uint256 profitAmount) {
    uint256 currentBalance = getTotalUtilizedAssets();
    uint256 initialBalance = strategyBalance(); // Now accurately tracks total strategy balance

    if (currentBalance > initialBalance) {
      profitAmount = currentBalance - initialBalance;
    } else {
      profitAmount = 0;
    }
  }

  /// @notice Get current loss amount for entire strategy (0 if in profit)
  /// @return lossAmount Current loss amount
  function getCurrentLoss() external view returns (uint256 lossAmount) {
    uint256 currentBalance = getTotalUtilizedAssets();
    uint256 initialBalance = strategyBalance(); // Now accurately tracks total strategy balance

    if (currentBalance < initialBalance) {
      lossAmount = initialBalance - currentBalance;
    } else {
      lossAmount = 0;
    }
  }

  /// @notice Get strategy performance metrics for entire strategy
  /// @return totalUtilized Total strategy balance (same as initialBalance for compatibility)
  /// @return currentUtilized Current utilized assets (BaseVol + Morpho)
  /// @return totalProfit Total profit realized
  /// @return totalLoss Total loss realized
  /// @return netPerformance Net performance (profit - loss)
  function getStrategyMetrics()
    external
    view
    returns (
      uint256 totalUtilized,
      uint256 currentUtilized,
      uint256 totalProfit,
      uint256 totalLoss,
      int256 netPerformance
    )
  {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();

    uint256 initialBalance = $.strategyBalance; // Total strategy balance
    totalUtilized = initialBalance; // For backward compatibility
    currentUtilized = getTotalUtilizedAssets();

    // Calculate realized profit/loss from total strategy balance changes
    if (currentUtilized > initialBalance) {
      totalProfit = currentUtilized - initialBalance;
      totalLoss = 0;
    } else if (currentUtilized < initialBalance) {
      totalProfit = 0;
      totalLoss = initialBalance - currentUtilized;
    } else {
      totalProfit = 0;
      totalLoss = 0;
    }

    netPerformance = int256(totalProfit) - int256(totalLoss);
  }

  function setStrategyStatus(StrategyStatus newStatus) external authCaller(operator()) {
    _setStrategyStatus(newStatus);
  }

  /// @notice Initialize morphoInitialBalance after contract upgrade
  /// @dev One-time function to set morphoInitialBalance to current Morpho assets
  /// @dev Should be called immediately after upgrade if Morpho has existing assets
  function initializeMorphoBalance() external onlyOwner {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    require($.morphoInitialBalance == 0, "Morpho already initialized");

    uint256 currentMorphoAssets = getMorphoAssets();
    if (currentMorphoAssets > 0) {
      $.morphoInitialBalance = currentMorphoAssets;
      emit DebugLog(
        string(
          abi.encodePacked("Initialized morphoInitialBalance to ", currentMorphoAssets.toString())
        )
      );
    }
  }

  /// @notice Initialize baseVolInitialBalance after contract upgrade
  /// @dev One-time function to set baseVolInitialBalance to current BaseVol assets
  /// @dev Should be called immediately after upgrade if BaseVol has existing assets
  function initializeBaseVolBalance() external onlyOwner {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    require($.baseVolInitialBalance == 0, "BaseVol already initialized");

    uint256 currentBaseVolAssets = getBaseVolAssets();
    if (currentBaseVolAssets > 0) {
      $.baseVolInitialBalance = currentBaseVolAssets;
      emit DebugLog(
        string(
          abi.encodePacked("Initialized baseVolInitialBalance to ", currentBaseVolAssets.toString())
        )
      );
    }
  }

  /// @notice Reset strategyBalance to match current real assets
  /// @dev Emergency function to fix incorrect strategyBalance
  /// @dev Only callable by owner when strategy is idle
  /// @dev This will reset PnL tracking to zero
  function resetStrategyBalance() external onlyOwner whenIdle {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();

    uint256 currentBaseVol = getBaseVolAssets();
    uint256 currentMorpho = getMorphoAssets();
    uint256 totalAssets = currentBaseVol + currentMorpho;

    emit StrategyBalanceReset(
      $.strategyBalance,
      totalAssets,
      $.baseVolInitialBalance,
      currentBaseVol,
      $.morphoInitialBalance,
      currentMorpho
    );

    $.strategyBalance = totalAssets;
    $.baseVolInitialBalance = currentBaseVol;
    $.morphoInitialBalance = currentMorpho;
  }

  /*//////////////////////////////////////////////////////////////
                           PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

  function _setOperator(address newOperator) internal {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    if ($.operator != newOperator) {
      $.operator = newOperator;
      emit OperatorUpdated(_msgSender(), newOperator);
    }
  }

  function _validateStrategyStatus(StrategyStatus targetStatus) private view {
    StrategyStatus currentStatus = strategyStatus();
    if (currentStatus != targetStatus) {
      revert InvalidStrategyStatus(uint8(currentStatus), uint8(targetStatus));
    }
  }

  function _setStrategyStatus(StrategyStatus newStatus) private {
    GenesisStrategyStorage.layout().strategyStatus = newStatus;
  }

  function _updateLossStatistics(uint256 lossAmount, uint256 lossPercentage) internal {
    if (lossPercentage > 0.3 ether) {
      emit LossDetected(lossAmount, lossPercentage, "CRITICAL");
    } else if (lossPercentage > 0.1 ether) {
      emit LossDetected(lossAmount, lossPercentage, "HIGH");
    } else {
      emit LossDetected(lossAmount, lossPercentage, "NORMAL");
    }
  }

  function vault() public view returns (address) {
    return address(GenesisStrategyStorage.layout().vault);
  }

  function baseVolManager() public view returns (address) {
    return address(GenesisStrategyStorage.layout().baseVolManager);
  }

  function clearingHouse() public view returns (address) {
    return address(GenesisStrategyStorage.layout().clearingHouse);
  }

  function operator() public view returns (address) {
    return GenesisStrategyStorage.layout().operator;
  }

  function asset() public view returns (address) {
    return address(GenesisStrategyStorage.layout().asset);
  }

  function strategyStatus() public view returns (StrategyStatus) {
    return GenesisStrategyStorage.layout().strategyStatus;
  }

  /// @notice Get total assets under management including idle assets in strategy
  /// @dev This includes strategy idle assets + BaseVol assets + Morpho assets (real-time)
  /// @return Total assets managed by this strategy
  function totalAssetsUnderManagement() public view returns (uint256) {
    return getStrategyIdleAssets() + getBaseVolAssets() + getMorphoAssets();
  }

  /**
   * @notice Returns the breakdown of assets under management by location
   * @dev Returns three separate values for different asset locations
   * @return strategyIdleAssets The amount of idle assets held in the strategy contract
   * @return baseVolAssets The amount of assets deployed in BaseVol
   * @return morphoAssets The amount of assets deployed in Morpho
   */
  function assetsUnderManagement() public view returns (uint256, uint256, uint256) {
    return (getStrategyIdleAssets(), getBaseVolAssets(), getMorphoAssets());
  }

  function strategyBalance() public view returns (uint256) {
    return GenesisStrategyStorage.layout().strategyBalance;
  }

  function getStrategyIdleAssets() public view returns (uint256) {
    return IERC20(asset()).balanceOf(address(this));
  }

  /*//////////////////////////////////////////////////////////////
                          MORPHO INTEGRATION
    //////////////////////////////////////////////////////////////*/

  /// @notice Callback function called by MorphoVaultManager after deposit completion
  /// @dev Only callable by MorphoVaultManager
  /// @param amount The amount that was deposited
  /// @param success Whether the deposit was successful
  function morphoDepositCompletedCallback(
    uint256 amount,
    bool success
  ) external authCaller(morphoVaultManager()) {
    if (success) {
      GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
      $.strategyBalance += amount; // Track Morpho deposits in strategyBalance
      $.morphoInitialBalance += amount; // Track for profit/loss calculation
      emit MorphoUtilize(_msgSender(), amount);
    }

    // Reset status regardless of success/failure
    _setStrategyStatus(StrategyStatus.IDLE);

    if (!success) {
      emit DebugLog("Morpho deposit operation failed");
    }
  }

  /// @notice Callback function called by MorphoVaultManager after redeem completion
  /// @dev Only callable by MorphoVaultManager
  /// @param shares The amount of shares that were redeemed
  /// @param assets The amount of assets received
  /// @param success Whether the redeem was successful
  function morphoRedeemCompletedCallback(
    uint256 shares,
    uint256 assets,
    bool success
  ) external authCaller(morphoVaultManager()) {
    if (success) {
      GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();

      // Calculate profit/loss before updating state
      uint256 currentMorphoBalance = getMorphoAssets();
      uint256 actualMorphoBalance = currentMorphoBalance + assets;

      if (actualMorphoBalance != $.morphoInitialBalance) {
        if (actualMorphoBalance > $.morphoInitialBalance) {
          // Profit detected
          uint256 profit = actualMorphoBalance - $.morphoInitialBalance;
          $.strategyBalance += profit;
          emit DebugLog(
            string(abi.encodePacked("Morpho profit detected (redeem): ", profit.toString()))
          );
        } else {
          // Loss detected
          uint256 loss = $.morphoInitialBalance - actualMorphoBalance;
          uint256 lossPercentage = (loss * FLOAT_PRECISION) / $.morphoInitialBalance;

          _updateLossStatistics(loss, lossPercentage);

          if (loss >= $.strategyBalance) {
            $.strategyBalance = 0;
          } else {
            $.strategyBalance -= loss;
          }
          emit DebugLog(
            string(abi.encodePacked("Morpho loss detected (redeem): ", loss.toString()))
          );
        }
        $.morphoInitialBalance = actualMorphoBalance;
      }

      // Update state after profit/loss calculation
      $.strategyBalance -= assets;
      $.morphoInitialBalance -= assets;

      emit MorphoDeutilize(_msgSender(), assets);
    }

    // Reset status regardless of success/failure
    _setStrategyStatus(StrategyStatus.IDLE);

    if (!success) {
      emit DebugLog("Morpho redeem operation failed");
    }
  }

  /*//////////////////////////////////////////////////////////////
                          BALANCE AND ALLOCATION QUERIES
    //////////////////////////////////////////////////////////////*/

  /// @notice Get total utilized assets across all managers
  function getTotalUtilizedAssets() public view returns (uint256) {
    return getBaseVolAssets() + getMorphoAssets();
  }

  /// @notice Get assets currently in BaseVol (for share price calculation - includes escrowed funds)
  function getBaseVolAssets() public view returns (uint256) {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    if (address($.baseVolManager) == address(0)) return 0;
    return $.baseVolManager.totalClearingHouseBalance();
  }

  /// @notice Get withdrawable assets currently in BaseVol (for withdrawal operations)
  function getWithdrawableBaseVolAssets() public view returns (uint256) {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    if (address($.baseVolManager) == address(0)) return 0;
    return $.baseVolManager.withdrawableClearingHouseBalance();
  }

  /// @notice Get assets currently in Morpho
  function getMorphoAssets() public view returns (uint256) {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    if (address($.morphoVaultManager) == address(0)) return 0;
    return $.morphoVaultManager.morphoAssetBalance();
  }

  /// @notice Get current allocation percentages
  /// @return morphoPct Current Morpho allocation percentage
  /// @return baseVolPct Current BaseVol allocation percentage
  function getCurrentAllocation() public view returns (uint256 morphoPct, uint256 baseVolPct) {
    uint256 totalAssets = getTotalUtilizedAssets();
    if (totalAssets == 0) return (0, 0);

    uint256 morphoAssets = getMorphoAssets();
    uint256 baseVolAssets = getBaseVolAssets();

    morphoPct = (morphoAssets * FLOAT_PRECISION) / totalAssets;
    baseVolPct = (baseVolAssets * FLOAT_PRECISION) / totalAssets;
  }

  /// @notice Get target allocation percentages
  /// @return morphoPct Target Morpho allocation percentage
  /// @return baseVolPct Target BaseVol allocation percentage
  function getTargetAllocation() public view returns (uint256 morphoPct, uint256 baseVolPct) {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    return ($.morphoTargetPct, $.baseVolTargetPct);
  }

  /// @notice Check if rebalancing is needed
  /// @return needed Whether rebalancing is needed
  /// @return morphoDiff Absolute difference for Morpho allocation
  /// @return baseVolDiff Absolute difference for BaseVol allocation
  function shouldRebalance()
    public
    view
    returns (bool needed, uint256 morphoDiff, uint256 baseVolDiff)
  {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();

    (uint256 currentMorphoPct, uint256 currentBaseVolPct) = getCurrentAllocation();

    // If Morpho is not configured, only check BaseVol allocation
    bool morphoConfigured = address($.morphoVaultManager) != address(0);

    if (morphoConfigured) {
      // Calculate absolute differences for both allocations
      morphoDiff = currentMorphoPct > $.morphoTargetPct
        ? currentMorphoPct - $.morphoTargetPct
        : $.morphoTargetPct - currentMorphoPct;

      baseVolDiff = currentBaseVolPct > $.baseVolTargetPct
        ? currentBaseVolPct - $.baseVolTargetPct
        : $.baseVolTargetPct - currentBaseVolPct;

      // Check if any difference exceeds threshold
      needed = morphoDiff > $.rebalanceThreshold || baseVolDiff > $.rebalanceThreshold;
    } else {
      // Morpho not configured: only check BaseVol allocation
      // Target is 10% BaseVol, 90% idle
      morphoDiff = 0; // Not applicable

      baseVolDiff = currentBaseVolPct > $.baseVolTargetPct
        ? currentBaseVolPct - $.baseVolTargetPct
        : $.baseVolTargetPct - currentBaseVolPct;

      // Only check BaseVol difference
      needed = baseVolDiff > $.rebalanceThreshold;
    }
  }

  function morphoVaultManager() public view returns (address) {
    return address(GenesisStrategyStorage.layout().morphoVaultManager);
  }

  /*//////////////////////////////////////////////////////////////
                          REBALANCING LOGIC
    //////////////////////////////////////////////////////////////*/

  /// @notice Deposits to BaseVol with config validation
  function _depositToBaseVol(uint256 amount) internal {
    if (amount == 0) return;
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    (uint256 max, uint256 min, ) = $.baseVolManager.config();
    if (amount < min) return;
    uint256 adjusted = amount > max ? max : amount;
    IERC20(asset()).safeTransfer(address($.baseVolManager), adjusted);
    $.baseVolManager.depositToClearingHouse(adjusted);
  }

  /// @notice Deposits to Morpho with config validation
  function _depositToMorpho(uint256 amount) internal {
    if (amount == 0) return;
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    (uint256 max, uint256 min) = $.morphoVaultManager.config();
    if (amount < min) return;
    uint256 adjusted = amount > max ? max : amount;
    IERC20(asset()).safeTransfer(address($.morphoVaultManager), adjusted);
    $.morphoVaultManager.depositToMorpho(adjusted);
  }

  /// @notice Execute rebalancing between BaseVol and Morpho/idle with idle assets
  /// @dev Handles three cases: increase BaseVol, increase Morpho, or already balanced
  /// @dev If Morpho is not configured, keeps 90% as idle and 10% in BaseVol
  /// @dev Assumes all vault assets have already been transferred to strategy
  /// @param currentBaseVol Current assets in BaseVol
  /// @param currentMorpho Current assets in Morpho
  /// @param targetBaseVol Target assets for BaseVol
  /// @param targetMorpho Target assets for Morpho (or idle if Morpho not configured)
  /// @param idleAssets Available idle assets in strategy
  /// @param morphoConfigured Whether Morpho is configured
  function _executeRebalancing(
    uint256 currentBaseVol,
    uint256 currentMorpho,
    uint256 targetBaseVol,
    uint256 targetMorpho,
    uint256 idleAssets,
    bool morphoConfigured
  ) internal {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    _setStrategyStatus(StrategyStatus.REBALANCING);

    // If Morpho is not configured, rebalance to keep 90% idle and 10% BaseVol
    if (!morphoConfigured) {
      _executeRebalancingWithoutMorpho(currentBaseVol, targetBaseVol, idleAssets);
      return;
    }

    // Case 1: Need to increase BaseVol
    if (currentBaseVol < targetBaseVol) {
      uint256 needed = targetBaseVol - currentBaseVol;

      emit DebugLog(
        string(
          abi.encodePacked(
            "Case 1: Increase BaseVol by ",
            needed.toString(),
            " (idle=",
            idleAssets.toString(),
            ")"
          )
        )
      );

      // Use idle assets first
      if (idleAssets >= needed) {
        _depositToBaseVol(needed);
        _depositToMorpho(idleAssets - needed);
        return;
      }

      // Need to withdraw from Morpho
      uint256 fromMorpho = needed - idleAssets;
      if (currentMorpho >= fromMorpho) {
        _depositToBaseVol(idleAssets);
        $.morphoVaultManager.withdrawFromMorpho(fromMorpho);
        return;
      }

      // Not enough assets to reach target - use all available
      emit DebugLog("Insufficient assets to reach target BaseVol");
      _depositToBaseVol(idleAssets);
      if (currentMorpho > 0) {
        $.morphoVaultManager.withdrawFromMorpho(currentMorpho);
      }
      return;
    }

    // Case 2: Need to increase Morpho (or decrease BaseVol)
    if (currentBaseVol > targetBaseVol) {
      uint256 excess = currentBaseVol - targetBaseVol;

      emit DebugLog(
        string(
          abi.encodePacked(
            "Case 2: Decrease BaseVol by ",
            excess.toString(),
            " (idle=",
            idleAssets.toString(),
            ")"
          )
        )
      );

      // Withdraw excess from BaseVol (will be deposited to Morpho via callback)
      $.baseVolManager.withdrawFromClearingHouse(excess);
      _depositToMorpho(idleAssets);
      return;
    }

    // Case 3: Already balanced, just utilize idle assets according to target ratio
    emit DebugLog(
      string(abi.encodePacked("Case 3: Already balanced, utilizing idle=", idleAssets.toString()))
    );

    if (idleAssets > 0) {
      uint256 toBaseVol = idleAssets.mulDiv($.baseVolTargetPct, FLOAT_PRECISION);
      _depositToBaseVol(toBaseVol);
      _depositToMorpho(idleAssets - toBaseVol);
    } else {
      _setStrategyStatus(StrategyStatus.IDLE);
    }

    emit RebalancingCompleted(currentMorpho, currentBaseVol, targetMorpho, targetBaseVol);
  }

  /// @notice Execute rebalancing when Morpho is not configured (10% BaseVol, 90% idle)
  /// @dev Withdraws excess from BaseVol or deposits to BaseVol to reach target
  /// @dev Assumes all vault assets have already been transferred to strategy
  /// @param currentBaseVol Current assets in BaseVol
  /// @param targetBaseVol Target assets for BaseVol (10% of total)
  /// @param idleAssets Available idle assets in strategy
  function _executeRebalancingWithoutMorpho(
    uint256 currentBaseVol,
    uint256 targetBaseVol,
    uint256 idleAssets
  ) internal {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();

    emit DebugLog(
      string(
        abi.encodePacked(
          "Rebalancing without Morpho: CurrentBV=",
          currentBaseVol.toString(),
          " TargetBV=",
          targetBaseVol.toString(),
          " Idle=",
          idleAssets.toString()
        )
      )
    );

    // Case 1: Need to increase BaseVol (currently < 10%)
    if (currentBaseVol < targetBaseVol) {
      uint256 needed = targetBaseVol - currentBaseVol;
      _depositToBaseVol(idleAssets >= needed ? needed : idleAssets);
      _setStrategyStatus(StrategyStatus.IDLE);
      return;
    }

    // Case 2: Need to decrease BaseVol (currently > 10%)
    if (currentBaseVol > targetBaseVol) {
      uint256 excess = currentBaseVol - targetBaseVol;

      // Withdraw excess from BaseVol to idle (will stay in strategy)
      $.baseVolManager.withdrawFromClearingHouse(excess);
      emit DebugLog(
        string(abi.encodePacked("Withdrawing ", excess.toString(), " from BaseVol to keep as idle"))
      );
      // Callback will handle setting status back to IDLE
      return;
    }

    // Case 3: Already at target (10% BaseVol, 90% idle)
    emit DebugLog("Already balanced at 10% BaseVol, 90% idle");
    _setStrategyStatus(StrategyStatus.IDLE);
  }

  /// @notice Enhanced withdraw callback that handles rebalancing and profit/loss tracking
  /// @notice Callback function called by BaseVolManager after withdraw completion
  /// @dev Only callable by BaseVolManager
  /// @param amount The amount that was withdrawn
  /// @param success Whether the withdraw was successful
  function baseVolWithdrawCompletedCallback(
    uint256 amount,
    bool success
  ) external authCaller(baseVolManager()) {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();

    if (success) {
      // Calculate profit/loss before updating state (similar to Morpho logic)
      uint256 currentBaseVolBalance = getBaseVolAssets();
      uint256 actualBaseVolBalance = currentBaseVolBalance + amount;

      if (actualBaseVolBalance != $.baseVolInitialBalance) {
        if (actualBaseVolBalance > $.baseVolInitialBalance) {
          // Profit detected
          uint256 profit = actualBaseVolBalance - $.baseVolInitialBalance;
          $.strategyBalance += profit;
          emit DebugLog(string(abi.encodePacked("BaseVol profit detected: ", profit.toString())));
        } else {
          // Loss detected
          uint256 loss = $.baseVolInitialBalance - actualBaseVolBalance;
          uint256 lossPercentage = (loss * FLOAT_PRECISION) / $.baseVolInitialBalance;

          _updateLossStatistics(loss, lossPercentage);

          if (loss >= $.strategyBalance) {
            $.strategyBalance = 0;
          } else {
            $.strategyBalance -= loss;
          }
          emit DebugLog(string(abi.encodePacked("BaseVol loss detected: ", loss.toString())));
        }
        $.baseVolInitialBalance = actualBaseVolBalance;
      }

      // Update state after profit/loss calculation
      $.strategyBalance -= amount;
      $.baseVolInitialBalance -= amount;

      // Check if this is a settlement withdrawal
      if ($.isSettlementWithdrawal) {
        // Check strategy balance before transfer
        uint256 strategyBalance = IERC20(asset()).balanceOf(address(this));
        uint256 transferAmount = amount > strategyBalance ? strategyBalance : amount;

        if (transferAmount < amount) {
          emit DebugLog(
            string(
              abi.encodePacked(
                "Warning: Strategy balance insufficient. Expected: ",
                amount.toString(),
                ", Available: ",
                strategyBalance.toString()
              )
            )
          );
        }

        // Transfer to vault as idle assets
        if (transferAmount > 0) {
          IERC20(asset()).safeTransfer(address(vault()), transferAmount);
        }

        emit DebugLog(
          string(
            abi.encodePacked(
              "Settlement withdrawal from BaseVol completed: ",
              transferAmount.toString()
            )
          )
        );

        // Check if all settlement withdrawals are complete (no more assets in BaseVol or Morpho)
        bool allWithdrawn = getBaseVolAssets() == 0 && getMorphoAssets() == 0;
        if (allWithdrawn) {
          $.isSettlementWithdrawal = false;
          _setStrategyStatus(StrategyStatus.IDLE);
          emit DebugLog("All settlement withdrawals complete");
        }

        emit BaseVolDeutilize(_msgSender(), amount);
        return;
      }

      // Check if we're in deutilizing mode (stop() was called)
      if (strategyStatus() == StrategyStatus.DEUTILIZING) {
        // Transfer all assets to vault
        IERC20(asset()).safeTransfer(address(vault()), amount);

        emit DebugLog(
          string(
            abi.encodePacked(
              "Deutilizing: Transferred ",
              amount.toString(),
              " from BaseVol to vault"
            )
          )
        );

        // Check if all withdrawals are complete (no more assets in BaseVol or Morpho)
        bool allWithdrawn = getBaseVolAssets() == 0 && getMorphoAssets() == 0;
        if (allWithdrawn) {
          _setStrategyStatus(StrategyStatus.IDLE);
          emit DebugLog("Deutilizing complete: All assets transferred to vault");
        }

        emit BaseVolDeutilize(_msgSender(), amount);
        return;
      }

      // Check if we're in rebalancing mode
      if (strategyStatus() == StrategyStatus.REBALANCING) {
        if (address($.morphoVaultManager) != address(0)) {
          _depositToMorpho(amount);
        } else {
          _setStrategyStatus(StrategyStatus.IDLE);
        }
        return;
      }

      // Check if this is part of a vault withdrawal request
      uint256 remainingNeeded = $.pendingWithdrawAmount;
      if (remainingNeeded > 0) {
        // Transfer to vault first
        IERC20(asset()).safeTransfer(address(vault()), amount);

        // Calculate how much we still need after this withdrawal
        uint256 stillNeeded = remainingNeeded > amount ? remainingNeeded - amount : 0;

        // Continue with Morpho if still need more
        if (stillNeeded > 0 && address($.morphoVaultManager) != address(0)) {
          uint256 morphoAvailable = getMorphoAssets();
          if (morphoAvailable > 0) {
            uint256 fromMorpho = Math.min(stillNeeded, morphoAvailable);
            $.pendingWithdrawAmount = stillNeeded - fromMorpho; // Update remaining needed
            $.morphoVaultManager.withdrawFromMorpho(fromMorpho);
            emit DebugLog(
              string(
                abi.encodePacked(
                  "Continuing to Morpho: ",
                  fromMorpho.toString(),
                  " (still needed after: ",
                  (stillNeeded - fromMorpho).toString(),
                  ")"
                )
              )
            );
            return; // Will continue in morphoWithdrawCompletedCallback
          }
        }

        // Clear pending amount as we're done (either fulfilled or no more sources)
        $.pendingWithdrawAmount = 0;
        if (stillNeeded > 0) {
          emit DebugLog(
            string(
              abi.encodePacked(
                "Withdrawal partially fulfilled from BaseVol. Unfulfilled: ",
                stillNeeded.toString()
              )
            )
          );
        } else {
          emit DebugLog("Withdrawal request fully fulfilled from BaseVol");
        }
      } else {
        // Normal operation: transfer assets back to vault
        IERC20(asset()).safeTransfer(address(vault()), amount);
      }

      emit BaseVolDeutilize(_msgSender(), amount);
    }

    // Reset status
    if (strategyStatus() != StrategyStatus.REBALANCING) {
      _setStrategyStatus(StrategyStatus.IDLE);
    }
  }

  /// @notice Enhanced Morpho withdraw callback that handles rebalancing
  function morphoWithdrawCompletedCallback(
    uint256 amount,
    bool success
  ) external authCaller(morphoVaultManager()) {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();

    if (success) {
      // Calculate profit/loss before updating state (similar to BaseVol logic)
      uint256 currentMorphoBalance = getMorphoAssets();
      uint256 actualMorphoBalance = currentMorphoBalance + amount;

      if (actualMorphoBalance != $.morphoInitialBalance) {
        if (actualMorphoBalance > $.morphoInitialBalance) {
          // Profit detected
          uint256 profit = actualMorphoBalance - $.morphoInitialBalance;
          $.strategyBalance += profit;
          emit DebugLog(string(abi.encodePacked("Morpho profit detected: ", profit.toString())));
        } else {
          // Loss detected
          uint256 loss = $.morphoInitialBalance - actualMorphoBalance;
          uint256 lossPercentage = (loss * FLOAT_PRECISION) / $.morphoInitialBalance;

          _updateLossStatistics(loss, lossPercentage);

          if (loss >= $.strategyBalance) {
            $.strategyBalance = 0;
          } else {
            $.strategyBalance -= loss;
          }
          emit DebugLog(string(abi.encodePacked("Morpho loss detected: ", loss.toString())));
        }
        $.morphoInitialBalance = actualMorphoBalance;
      }

      // Update state after profit/loss calculation
      $.strategyBalance -= amount;
      $.morphoInitialBalance -= amount;

      // Check if this is a settlement withdrawal
      if ($.isSettlementWithdrawal) {
        // Check strategy balance before transfer
        uint256 strategyBalance = IERC20(asset()).balanceOf(address(this));
        uint256 transferAmount = amount > strategyBalance ? strategyBalance : amount;

        if (transferAmount < amount) {
          emit DebugLog(
            string(
              abi.encodePacked(
                "Warning: Strategy balance insufficient. Expected: ",
                amount.toString(),
                ", Available: ",
                strategyBalance.toString()
              )
            )
          );
        }

        // Transfer to vault as idle assets
        if (transferAmount > 0) {
          IERC20(asset()).safeTransfer(address(vault()), transferAmount);
        }

        emit DebugLog(
          string(
            abi.encodePacked(
              "Settlement withdrawal from Morpho completed: ",
              transferAmount.toString()
            )
          )
        );

        // Check if all settlement withdrawals are complete (no more assets in BaseVol or Morpho)
        bool allWithdrawn = getBaseVolAssets() == 0 && getMorphoAssets() == 0;
        if (allWithdrawn) {
          $.isSettlementWithdrawal = false;
          _setStrategyStatus(StrategyStatus.IDLE);
          emit DebugLog("All settlement withdrawals complete");
        }

        emit MorphoDeutilize(_msgSender(), amount);
        return;
      }

      // Check if we're in deutilizing mode (stop() was called)
      if (strategyStatus() == StrategyStatus.DEUTILIZING) {
        // Transfer all assets to vault
        IERC20(asset()).safeTransfer(address(vault()), amount);

        emit DebugLog(
          string(
            abi.encodePacked(
              "Deutilizing: Transferred ",
              amount.toString(),
              " from Morpho to vault"
            )
          )
        );

        // Check if all withdrawals are complete (no more assets in BaseVol or Morpho)
        bool allWithdrawn = getBaseVolAssets() == 0 && getMorphoAssets() == 0;
        if (allWithdrawn) {
          _setStrategyStatus(StrategyStatus.IDLE);
          emit DebugLog("Deutilizing complete: All assets transferred to vault");
        }

        emit MorphoDeutilize(_msgSender(), amount);
        return;
      }

      // Check if we're in rebalancing mode
      if (strategyStatus() == StrategyStatus.REBALANCING) {
        _depositToBaseVol(amount);
        return;
      }

      // Check if this is part of a vault withdrawal request
      uint256 remainingNeeded = $.pendingWithdrawAmount;
      if (remainingNeeded > 0) {
        // Transfer to vault for withdrawal request
        IERC20(asset()).safeTransfer(address(vault()), amount);

        // Calculate if we still need more (should be 0 or very small)
        uint256 stillNeeded = remainingNeeded > amount ? remainingNeeded - amount : 0;
        $.pendingWithdrawAmount = 0; // Clear as Morpho is typically the final step

        if (stillNeeded > 0) {
          emit DebugLog(
            string(
              abi.encodePacked(
                "Withdrawal request partially fulfilled from Morpho. Unfulfilled: ",
                stillNeeded.toString()
              )
            )
          );
        } else {
          emit DebugLog("Withdrawal request fully fulfilled from Morpho");
        }
      } else {
        // Normal operation: this shouldn't happen for Morpho in current design
        // but handle it gracefully
        IERC20(asset()).safeTransfer(address(vault()), amount);
        emit DebugLog("Morpho withdrawal outside of vault request");
      }

      emit MorphoDeutilize(_msgSender(), amount);
    }

    // Reset status if not in rebalancing mode
    if (strategyStatus() != StrategyStatus.REBALANCING) {
      _setStrategyStatus(StrategyStatus.IDLE);
    }

    if (!success) {
      emit DebugLog("Morpho withdraw operation failed");
      // Clear pending amount on failure
      $.pendingWithdrawAmount = 0;
    }
  }
}
