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

  event Utilize(address indexed caller, uint256 assetDelta, uint256 productDelta);
  event Deutilize(address indexed caller, uint256 productDelta, uint256 assetDelta);
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

  event MaxUtilizePctUpdated(address indexed account, uint256 newPct);
  event Stopped(address indexed account);
  event LossDetected(uint256 lossAmount, uint256 lossPercentage, string severity);
  event EmergencyWithdraw(uint256 amount, uint256 remainingBalance);
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

    _setMaxUtilizePct(1 ether); // no cap by default(100%)

    // Set default target allocations: 90% Morpho, 10% BaseVol
    $.morphoTargetPct = 0.9 ether; // 90%
    $.baseVolTargetPct = 0.1 ether; // 10%
    $.rebalanceThreshold = 0.05 ether; // 5% threshold
  }

  function utilize(uint256 amount) public authCaller(operator()) nonReentrant {
    _utilize(amount);
  }

  /// @notice Utilizes assets from Vault to ClearingHouse for BaseVol orders.
  /// @dev Uses assets in vault. Callable only by the operator.
  /// @param amount The underlying asset amount to be utilized.
  function _utilize(uint256 amount) internal whenIdle {
    _setStrategyStatus(StrategyStatus.UTILIZING);

    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    IGenesisVault _vault = $.vault;

    if (amount == 0) {
      revert ZeroAmountUtilization();
    }

    uint256 maxUtilization = _vault.idleAssets().mulDiv(maxUtilizePct(), FLOAT_PRECISION);
    emit DebugLog(
      string(abi.encodePacked("Max utilization calculated: ", maxUtilization.toString()))
    );

    if (amount > maxUtilization) {
      emit DebugLog(
        string(
          abi.encodePacked(
            "Amount adjusted from ",
            amount.toString(),
            " to ",
            maxUtilization.toString()
          )
        )
      );
      amount = maxUtilization;
    }

    if (amount == 0) {
      revert ZeroAmountUtilization();
    }

    IERC20 _asset = $.asset;
    emit DebugLog(
      string(
        abi.encodePacked("Transferring ", amount.toString(), " assets from vault to baseVolManager")
      )
    );
    _asset.safeTransferFrom(address(_vault), address(baseVolManager()), amount);

    $.baseVolManager.depositToClearingHouse(amount);
    emit DebugLog("_utilize function completed successfully");
  }

  /// @notice Callback function called by BaseVolManager after deposit completion
  /// @dev Only callable by BaseVolManager
  /// @param amount The amount that was deposited
  /// @param success Whether the deposit was successful
  function depositCompletedCallback(
    uint256 amount,
    bool success
  ) external authCaller(baseVolManager()) {
    if (success) {
      // Update strategy state
      GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
      $.utilizedAssets += amount;
      $.strategyBalance += amount;
      emit Utilize(_msgSender(), amount, 0);
    }

    if (success) {
      _setStrategyStatus(StrategyStatus.IDLE);
    } else {
      // TODO: handle failed utilize
      emit DebugLog("Utilize operation failed");
    }
  }

  /// @notice Deutilizes assets from ClearingHouse back to Vault.
  /// @dev Callable only by the operator.
  function deutilize() public authCaller(operator()) nonReentrant {
    _deutilize();
  }

  /// @notice Internal deutilize function for internal calls
  function _deutilize() internal whenIdle {
    _setStrategyStatus(StrategyStatus.DEUTILIZING);

    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    uint256 currentBalance = $.baseVolManager.clearingHouseBalance();
    uint256 withdrawAmount = _calculateWithdrawAmount(currentBalance);

    // check if loss is greater than 30%
    if (currentBalance < $.strategyBalance) {
      uint256 lossPercentage = ((($.strategyBalance - currentBalance) * FLOAT_PRECISION) /
        $.strategyBalance);
      if (lossPercentage > 0.3 ether) {
        _setStrategyStatus(StrategyStatus.EMERGENCY);
      }
    }

    if (withdrawAmount == 0) {
      if (strategyStatus() != StrategyStatus.EMERGENCY) {
        _setStrategyStatus(StrategyStatus.IDLE);
      }
      return;
    }
    $.baseVolManager.withdrawFromClearingHouse(withdrawAmount);
  }

  function _calculateWithdrawAmount(uint256 currentBalance) internal view returns (uint256) {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();

    if (currentBalance < $.strategyBalance) {
      uint256 loss = $.strategyBalance - currentBalance;
      uint256 lossPercentage = (loss * FLOAT_PRECISION) / $.strategyBalance;

      if (lossPercentage <= 0.3 ether) {
        return 0;
      } else {
        // if loss is greater than 30%, withdraw all assets
        return currentBalance;
      }
    }

    if (currentBalance > $.strategyBalance) {
      return currentBalance - $.strategyBalance;
    }
    return 0;
  }

  /*//////////////////////////////////////////////////////////////
                            KEEPER LOGIC   
    //////////////////////////////////////////////////////////////*/

  /// @notice Keeper-only rebalancing function - automatically performs appropriate actions based on the situation
  /// @dev Only callable by Operator and can only be executed in IDLE state
  /// @dev Priority: 1) Process withdrawal requests, 2) Deutilize according to strategy logic, 3) Rebalance allocations, 4) Utilize new funds
  function keeperRebalance() external authCaller(operator()) whenIdle nonReentrant {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    IGenesisVault _vault = $.vault;

    // Priority 1: Handle withdraw requests first
    uint256 pendingWithdraw = _vault.totalPendingWithdraw();
    uint256 availableInStrategy = assetsToWithdraw();

    if (pendingWithdraw > availableInStrategy) {
      // Need to deutilize to fulfill withdraw requests
      _deutilizeForWithdrawals(pendingWithdraw - availableInStrategy);
      emit KeeperAction("DEUTILIZE_FOR_WITHDRAW", pendingWithdraw);
      return;
    }

    // Priority 2: Check if we need to deutilize due to BaseVol strategy logic
    uint256 currentBalance = $.baseVolManager.clearingHouseBalance();
    if ($.strategyBalance > 0 && currentBalance > 0) {
      uint256 withdrawAmount = _calculateWithdrawAmount(currentBalance);
      if (withdrawAmount > 0) {
        _deutilize();
        emit KeeperAction("DEUTILIZE_STRATEGY_LOGIC", withdrawAmount);
        return;
      }
    }

    // Priority 3: Check if rebalancing is needed between Morpho and BaseVol
    (bool needsRebalance, uint256 morphoDiff, uint256 baseVolDiff) = shouldRebalance();
    if (needsRebalance && address($.morphoVaultManager) != address(0)) {
      _performRebalancing();
      emit KeeperAction("REBALANCE_ALLOCATIONS", morphoDiff + baseVolDiff);
      return;
    }

    // Priority 4: Utilize new funds if available
    uint256 idleAssets = _vault.idleAssets();
    if (idleAssets > 0) {
      uint256 maxUtilization = idleAssets.mulDiv(maxUtilizePct(), FLOAT_PRECISION);

      if (maxUtilization > 0 && strategyStatus() != StrategyStatus.EMERGENCY) {
        _utilizeNewFunds(maxUtilization);
        emit KeeperAction("UTILIZE_NEW_FUNDS", maxUtilization);
        return;
      }
    }

    // No action needed
    emit KeeperAction("NO_ACTION", 0);
  }

  /// @notice Processes idle assets for the withdraw requests.
  /// @dev Callable by anyone and only when strategy is in the IDLE status.
  function processAssetsToWithdraw() public whenIdle {
    address _asset = asset();
    uint256 _assetsToWithdraw = assetsToWithdraw();

    if (_assetsToWithdraw > 0) {
      IERC20(_asset).safeTransfer(vault(), _assetsToWithdraw);
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

  /// @notice Sets the limit percent given vault's total asset against utilize/deutilize amounts.
  function setMaxUtilizePct(uint256 value) external onlyOwner {
    _setMaxUtilizePct(value);
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

  /// @notice Get current PnL information
  /// @return isProfit Whether the strategy is in profit
  /// @return absolutePnL Absolute PnL amount (positive for profit, negative for loss)
  /// @return percentagePnL PnL as percentage of strategy balance
  /// @return currentBalance Current ClearingHouse balance
  /// @return initialStrategyBalance Initial strategy balance
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
    currentBalance = $.baseVolManager.clearingHouseBalance();
    initialStrategyBalance = $.strategyBalance;

    if (currentBalance > initialStrategyBalance) {
      isProfit = true;
      absolutePnL = int256(currentBalance - initialStrategyBalance);
      percentagePnL =
        ((currentBalance - initialStrategyBalance) * FLOAT_PRECISION) /
        initialStrategyBalance;
    } else if (currentBalance < initialStrategyBalance) {
      isProfit = false;
      absolutePnL = -int256(initialStrategyBalance - currentBalance);
      percentagePnL =
        ((initialStrategyBalance - currentBalance) * FLOAT_PRECISION) /
        initialStrategyBalance;
    } else {
      isProfit = false;
      absolutePnL = 0;
      percentagePnL = 0;
    }
  }

  /// @notice Get current profit amount (0 if in loss)
  /// @return profitAmount Current profit amount
  function getCurrentProfit() external view returns (uint256 profitAmount) {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    uint256 currentBalance = $.baseVolManager.clearingHouseBalance();

    if (currentBalance > $.strategyBalance) {
      profitAmount = currentBalance - $.strategyBalance;
    } else {
      profitAmount = 0;
    }
  }

  /// @notice Get current loss amount (0 if in profit)
  /// @return lossAmount Current loss amount
  function getCurrentLoss() external view returns (uint256 lossAmount) {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    uint256 currentBalance = $.baseVolManager.clearingHouseBalance();

    if (currentBalance < $.strategyBalance) {
      lossAmount = $.strategyBalance - currentBalance;
    } else {
      lossAmount = 0;
    }
  }

  /// @notice Get strategy performance metrics
  /// @return totalUtilized Total assets utilized
  /// @return currentUtilized Current utilized assets
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

    totalUtilized = $.utilizedAssets;
    currentUtilized = $.baseVolManager.clearingHouseBalance();

    // Calculate realized profit/loss from strategy balance changes
    if (currentUtilized > $.strategyBalance) {
      totalProfit = currentUtilized - $.strategyBalance;
      totalLoss = 0;
    } else if (currentUtilized < $.strategyBalance) {
      totalProfit = 0;
      totalLoss = $.strategyBalance - currentUtilized;
    } else {
      totalProfit = 0;
      totalLoss = 0;
    }

    netPerformance = int256(totalProfit) - int256(totalLoss);
  }

  function setStrategyStatus(StrategyStatus newStatus) external authCaller(operator()) {
    _setStrategyStatus(newStatus);
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

  function _setMaxUtilizePct(uint256 value) internal {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    $.maxUtilizePct = value;
    emit MaxUtilizePctUpdated(_msgSender(), value);
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

  function maxUtilizePct() public view returns (uint256) {
    return GenesisStrategyStorage.layout().maxUtilizePct;
  }

  function utilizedAssets() public view returns (uint256) {
    return GenesisStrategyStorage.layout().utilizedAssets;
  }

  function strategyBalance() public view returns (uint256) {
    return GenesisStrategyStorage.layout().strategyBalance;
  }

  function assetsToWithdraw() public view returns (uint256) {
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
      $.utilizedAssets += amount;
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
      $.utilizedAssets -= assets;
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

  /// @notice Get assets currently in BaseVol
  function getBaseVolAssets() public view returns (uint256) {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    if (address($.baseVolManager) == address(0)) return 0;
    return $.baseVolManager.clearingHouseBalance();
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

    // Calculate absolute differences
    morphoDiff = currentMorphoPct > $.morphoTargetPct
      ? currentMorphoPct - $.morphoTargetPct
      : $.morphoTargetPct - currentMorphoPct;

    baseVolDiff = currentBaseVolPct > $.baseVolTargetPct
      ? currentBaseVolPct - $.baseVolTargetPct
      : $.baseVolTargetPct - currentBaseVolPct;

    // Check if any difference exceeds threshold
    needed = morphoDiff > $.rebalanceThreshold || baseVolDiff > $.rebalanceThreshold;
  }

  function morphoVaultManager() public view returns (address) {
    return address(GenesisStrategyStorage.layout().morphoVaultManager);
  }

  /*//////////////////////////////////////////////////////////////
                          REBALANCING LOGIC
    //////////////////////////////////////////////////////////////*/

  /// @notice Performs automatic rebalancing between Morpho and BaseVol
  /// @dev Internal function called by keeperRebalance
  function _performRebalancing() internal {
    _setStrategyStatus(StrategyStatus.REBALANCING);

    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();

    uint256 totalAssets = getTotalUtilizedAssets();
    if (totalAssets == 0) {
      _setStrategyStatus(StrategyStatus.IDLE);
      return;
    }

    uint256 targetMorpho = totalAssets.mulDiv($.morphoTargetPct, FLOAT_PRECISION);
    uint256 targetBaseVol = totalAssets.mulDiv($.baseVolTargetPct, FLOAT_PRECISION);

    uint256 currentMorpho = getMorphoAssets();
    uint256 currentBaseVol = getBaseVolAssets();

    emit DebugLog(
      string(
        abi.encodePacked(
          "Rebalancing: Current M:",
          currentMorpho.toString(),
          " B:",
          currentBaseVol.toString(),
          " Target M:",
          targetMorpho.toString(),
          " B:",
          targetBaseVol.toString()
        )
      )
    );

    // Determine rebalancing direction
    if (currentMorpho < targetMorpho) {
      // Need to move assets from BaseVol to Morpho
      uint256 moveToMorpho = targetMorpho - currentMorpho;
      if (currentBaseVol >= moveToMorpho) {
        _moveFromBaseVolToMorpho(moveToMorpho);
      } else {
        // Move all available from BaseVol
        if (currentBaseVol > 0) {
          _moveFromBaseVolToMorpho(currentBaseVol);
        }
      }
    } else if (currentMorpho > targetMorpho) {
      // Need to move assets from Morpho to BaseVol
      uint256 moveFromMorpho = currentMorpho - targetMorpho;
      _moveFromMorphoToBaseVol(moveFromMorpho);
    }

    emit RebalancingCompleted(currentMorpho, currentBaseVol, targetMorpho, targetBaseVol);
  }

  /// @notice Moves assets from BaseVol to Morpho
  /// @param amount Amount to move
  function _moveFromBaseVolToMorpho(uint256 amount) internal {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();

    // Step 1: Withdraw from BaseVol
    if (address($.baseVolManager) != address(0)) {
      $.baseVolManager.withdrawFromClearingHouse(amount);
      // Note: Assets will be transferred to this strategy contract via callback
    }

    // Step 2: Deposit to Morpho (will be handled in the withdraw callback)
    // The withdraw callback will detect rebalancing status and deposit to Morpho
  }

  /// @notice Moves assets from Morpho to BaseVol
  /// @param amount Amount to move
  function _moveFromMorphoToBaseVol(uint256 amount) internal {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();

    // Step 1: Withdraw from Morpho
    if (address($.morphoVaultManager) != address(0)) {
      $.morphoVaultManager.withdrawFromMorpho(amount);
      // Note: Assets will be transferred to this strategy contract via callback
    }

    // Step 2: Deposit to BaseVol (will be handled in the withdraw callback)
    // The withdraw callback will detect rebalancing status and deposit to BaseVol
  }

  /// @notice Utilizes new funds according to target allocation
  /// @param amount Total amount to utilize
  function _utilizeNewFunds(uint256 amount) internal {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();

    // Distribute according to target percentages
    uint256 toMorpho = amount.mulDiv($.morphoTargetPct, FLOAT_PRECISION);
    uint256 toBaseVol = amount - toMorpho; // Remainder goes to BaseVol

    // Deposit to Morpho first (if manager exists)
    if (toMorpho > 0 && address($.morphoVaultManager) != address(0)) {
      IERC20(asset()).safeTransferFrom(address(vault()), address($.morphoVaultManager), toMorpho);
      $.morphoVaultManager.depositToMorpho(toMorpho);
    } else {
      // If no Morpho manager, add to BaseVol
      toBaseVol += toMorpho;
    }

    // Deposit to BaseVol
    if (toBaseVol > 0) {
      _utilize(toBaseVol);
    }
  }

  /// @notice Deutilizes assets for withdrawal requests intelligently
  /// @param amountNeeded Amount needed for withdrawals
  function _deutilizeForWithdrawals(uint256 amountNeeded) internal {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();

    uint256 remaining = amountNeeded;

    // First, try to withdraw from BaseVol (more liquid)
    uint256 baseVolAvailable = getBaseVolAssets();
    if (remaining > 0 && baseVolAvailable > 0) {
      uint256 fromBaseVol = Math.min(remaining, baseVolAvailable);
      $.baseVolManager.withdrawFromClearingHouse(fromBaseVol);
      remaining -= fromBaseVol;
    }

    // If still need more, withdraw from Morpho
    if (remaining > 0 && address($.morphoVaultManager) != address(0)) {
      uint256 morphoAvailable = getMorphoAssets();
      if (morphoAvailable > 0) {
        uint256 fromMorpho = Math.min(remaining, morphoAvailable);
        $.morphoVaultManager.withdrawFromMorpho(fromMorpho);
        remaining -= fromMorpho;
      }
    }
  }

  /// @notice Enhanced withdraw callback that handles rebalancing and profit/loss tracking
  /// @notice Callback function called by BaseVolManager after withdraw completion
  /// @dev Only callable by BaseVolManager
  /// @param amount The amount that was withdrawn
  /// @param success Whether the withdraw was successful
  function withdrawCompletedCallback(
    uint256 amount,
    bool success
  ) external authCaller(baseVolManager()) {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();

    if (success) {
      // Check the actual ClearingHouse balance for profit/loss calculation
      uint256 actualClearingHouseBalance = $.baseVolManager.clearingHouseBalance();

      // Update utilizedAssets considering profit or loss
      if (actualClearingHouseBalance != $.strategyBalance) {
        if (actualClearingHouseBalance > $.strategyBalance) {
          // Profit
          uint256 profit = actualClearingHouseBalance - $.strategyBalance;
          $.utilizedAssets += profit;
        } else {
          // Loss
          uint256 loss = $.strategyBalance - actualClearingHouseBalance;
          uint256 lossPercentage = (loss * FLOAT_PRECISION) / $.strategyBalance;

          _updateLossStatistics(loss, lossPercentage);

          if (loss >= $.utilizedAssets) {
            $.utilizedAssets = 0;
          } else {
            $.utilizedAssets -= loss;
          }
        }
        $.strategyBalance = actualClearingHouseBalance;
      }

      // Update state
      $.utilizedAssets -= amount;
      $.strategyBalance -= amount;

      // Check if we're in rebalancing mode
      if (strategyStatus() == StrategyStatus.REBALANCING) {
        // During rebalancing, move assets to Morpho
        if (address($.morphoVaultManager) != address(0)) {
          IERC20(asset()).safeTransfer(address($.morphoVaultManager), amount);
          $.morphoVaultManager.depositToMorpho(amount);
          return; // Don't transfer to vault during rebalancing
        }
      }

      // Normal operation: transfer assets back to vault
      IERC20(asset()).safeTransfer(address(vault()), amount);
      emit Deutilize(_msgSender(), 0, amount);
    }

    // Reset status
    if (success && strategyStatus() == StrategyStatus.EMERGENCY) {
      _setStrategyStatus(StrategyStatus.EMERGENCY);
    } else if (strategyStatus() != StrategyStatus.REBALANCING) {
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
      $.utilizedAssets -= amount;

      // Check if we're in rebalancing mode
      if (strategyStatus() == StrategyStatus.REBALANCING) {
        // During rebalancing, move assets to BaseVol
        IERC20(asset()).safeTransferFrom(address(this), address($.baseVolManager), amount);
        $.baseVolManager.depositToClearingHouse(amount);
        return; // Don't emit normal events during rebalancing
      }

      emit MorphoDeutilize(_msgSender(), amount);
    }

    // Reset status if not in rebalancing mode
    if (strategyStatus() != StrategyStatus.REBALANCING) {
      _setStrategyStatus(StrategyStatus.IDLE);
    }

    if (!success) {
      emit DebugLog("Morpho withdraw operation failed");
    }
  }
}
