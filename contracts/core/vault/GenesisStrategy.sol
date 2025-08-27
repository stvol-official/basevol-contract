// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IGenesisVault } from "./interfaces/IGenesisVault.sol";
import { IBaseVolManager } from "./interfaces/IBaseVolManager.sol";
import { IClearingHouse } from "../../interfaces/IClearingHouse.sol";
import { GenesisStrategyStorage, StrategyStatus } from "./storage/GenesisStrategyStorage.sol";
import { IGenesisStrategyErrors } from "./errors/GenesisStrategyErrors.sol";

contract GenesisStrategy is
  Initializable,
  PausableUpgradeable,
  Ownable2StepUpgradeable,
  ReentrancyGuardUpgradeable,
  IGenesisStrategyErrors
{
  using Math for uint256;
  using SafeERC20 for IERC20;
  using SafeCast for uint256;

  uint256 internal constant FLOAT_PRECISION = 1e18;

  event Utilize(address indexed caller, uint256 assetDelta, uint256 productDelta);
  event Deutilize(address indexed caller, uint256 productDelta, uint256 assetDelta);
  event BaseVolManagerUpdated(address indexed account, address indexed newBaseVolManager);
  event ClearingHouseUpdated(address indexed account, address indexed newClearingHouse);
  event OperatorUpdated(address indexed account, address indexed newOperator);
  event KeeperAction(string action, uint256 amount);

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

  constructor() {
    _disableInitializers();
  }

  function initialize(
    address _asset,
    address _vault,
    address _baseVolManager,
    address _clearingHouse,
    address _operator
  ) external initializer {
    __Ownable_init(_msgSender());
    __Pausable_init();
    __ReentrancyGuard_init();

    require(_asset != address(0), "Invalid asset address");
    require(_vault != address(0), "Invalid vault address");
    require(_baseVolManager != address(0), "Invalid BaseVolManager address");
    require(_clearingHouse != address(0), "Invalid ClearingHouse address");
    require(_operator != address(0), "Invalid operator address");

    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();

    $.asset = IERC20(_asset);
    $.vault = IGenesisVault(_vault);
    $.baseVolManager = IBaseVolManager(_baseVolManager);
    $.clearingHouse = IClearingHouse(_clearingHouse);
    $.operator = _operator;

    _setMaxUtilizePct(1 ether); // no cap by default(100%)
  }

  function utilize(uint256 amount) public authCaller(operator()) whenIdle nonReentrant {
    _utilize(amount);
  }

  /// @notice Utilizes assets from Vault to ClearingHouse for BaseVol orders.
  /// @dev Uses assets in vault. Callable only by the operator.
  /// @param amount The underlying asset amount to be utilized.
  function _utilize(uint256 amount) internal whenIdle nonReentrant {
    _setStrategyStatus(StrategyStatus.UTILIZING);

    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    IGenesisVault _vault = $.vault;

    if (amount == 0) {
      revert ZeroAmountUtilization();
    }

    uint256 maxUtilization = _vault.idleAssets().mulDiv(maxUtilizePct(), FLOAT_PRECISION);
    if (amount > maxUtilization) {
      amount = maxUtilization;
    }

    if (amount == 0) {
      revert ZeroAmountUtilization();
    }

    IERC20 _asset = $.asset;

    // Transfer assets from Vault to Strategy
    _asset.safeTransferFrom(address(_vault), address(this), amount);

    // Deposit to ClearingHouse through BaseVolManager
    _asset.approve(address($.baseVolManager), amount);
    $.baseVolManager.depositToClearingHouse(amount, address(this));
  }

  /// @notice Callback function called by BaseVolManager after deposit completion
  /// @dev Only callable by BaseVolManager
  /// @param amount The amount that was deposited
  /// @param success Whether the deposit was successful
  function depositCompletedCallback(
    uint256 amount,
    bool success
  ) external authCaller(baseVolManager()) nonReentrant {
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
      emit DebugLog("Utilize operation failed");
    }
  }

  /// @notice Deutilizes assets from ClearingHouse back to Vault.
  /// @dev Callable only by the operator.
  function deutilize() public authCaller(operator()) whenIdle nonReentrant {
    _deutilize();
  }

  /// @notice Internal deutilize function for internal calls
  function _deutilize() internal {
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
    $.baseVolManager.withdrawFromClearingHouse(withdrawAmount, address(this));
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

  /// @notice Callback function called by BaseVolManager after withdraw completion
  /// @dev Only callable by BaseVolManager
  /// @param amount The amount that was withdrawn
  /// @param success Whether the withdraw was successful
  function withdrawCompletedCallback(
    uint256 amount,
    bool success
  ) external authCaller(baseVolManager()) nonReentrant {
    if (success) {
      // Update strategy state
      GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();

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

      // Transfer assets back to Vault
      IERC20 _asset = $.asset;
      _asset.safeTransfer(address(vault()), amount);

      // Update state
      $.utilizedAssets -= amount;
      $.strategyBalance -= amount;

      emit Deutilize(_msgSender(), 0, amount);
    }

    if (success && strategyStatus() == StrategyStatus.EMERGENCY) {
      _setStrategyStatus(StrategyStatus.EMERGENCY);
    } else {
      _setStrategyStatus(StrategyStatus.IDLE);
    }
  }

  /*//////////////////////////////////////////////////////////////
                            KEEPER LOGIC   
    //////////////////////////////////////////////////////////////*/

  /// @notice Keeper-only rebalancing function - automatically performs appropriate actions based on the situation
  /// @dev Only callable by Operator and can only be executed in IDLE state
  /// @dev Priority: 1) Process withdrawal requests, 2) Deutilize according to strategy logic, 3) Utilize new funds
  function keeperRebalance() external authCaller(operator()) whenIdle nonReentrant {
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    IGenesisVault _vault = $.vault;

    // Priority 1: Handle withdraw requests first
    uint256 pendingWithdraw = _vault.totalPendingWithdraw();
    uint256 availableInStrategy = assetsToWithdraw();

    if (pendingWithdraw > availableInStrategy) {
      // Need to deutilize to fulfill withdraw requests
      _deutilize();
      emit KeeperAction("DEUTILIZE_FOR_WITHDRAW", pendingWithdraw);
      return;
    }

    // Priority 2: Check if we need to deutilize due to strategy logic
    uint256 currentBalance = $.baseVolManager.clearingHouseBalance();
    if ($.strategyBalance > 0 && currentBalance > 0) {
      uint256 withdrawAmount = _calculateWithdrawAmount(currentBalance);
      if (withdrawAmount > 0) {
        _deutilize();
        emit KeeperAction("DEUTILIZE_STRATEGY_LOGIC", withdrawAmount);
        return;
      }
    }

    // Priority 3: Utilize new funds if available
    uint256 idleAssets = _vault.idleAssets();
    if (idleAssets > 0) {
      uint256 maxUtilization = idleAssets.mulDiv(maxUtilizePct(), FLOAT_PRECISION);

      if (maxUtilization > 0 && strategyStatus() != StrategyStatus.EMERGENCY) {
        _utilize(maxUtilization);
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
}
