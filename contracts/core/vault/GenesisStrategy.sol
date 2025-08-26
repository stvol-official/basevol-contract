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

  /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

  event Utilize(address indexed caller, uint256 assetDelta, uint256 productDelta);
  event Deutilize(address indexed caller, uint256 productDelta, uint256 assetDelta);
  event BaseVolManagerUpdated(address indexed account, address indexed newBaseVolManager);
  event ClearingHouseUpdated(address indexed account, address indexed newClearingHouse);
  event OperatorUpdated(address indexed account, address indexed newOperator);

  event MaxUtilizePctUpdated(address indexed account, uint256 newPct);
  event Stopped(address indexed account);

  /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

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

  /*//////////////////////////////////////////////////////////////
                        INITIALIZATION
    //////////////////////////////////////////////////////////////*/

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

  /*//////////////////////////////////////////////////////////////
                            UTILIZE/DEUTILIZE   
    //////////////////////////////////////////////////////////////*/

  /// @notice Utilizes assets from Vault to ClearingHouse for BaseVol orders.
  /// @dev Uses assets in vault. Callable only by the operator.
  /// @param amount The underlying asset amount to be utilized.
  function utilize(uint256 amount) external virtual authCaller(operator()) whenIdle nonReentrant {
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

  /// @notice Deutilizes assets from ClearingHouse back to Vault.
  /// @dev Callable only by the operator.
  /// @param amount The amount of assets to be deutilized.
  function deutilize(uint256 amount) external authCaller(operator()) whenIdle nonReentrant {
    _deutilize(amount);
  }

  /// @notice Internal deutilize function for internal calls
  /// @param amount The amount of assets to be deutilized.
  function _deutilize(uint256 amount) internal {
    _setStrategyStatus(StrategyStatus.DEUTILIZING);

    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();

    require(amount > 0, "Amount must be positive");

    // Check the actual ClearingHouse balance
    uint256 actualClearingHouseBalance = $.baseVolManager.getClearingHouseBalance();

    // Update utilizedAssets considering profit or loss
    if (actualClearingHouseBalance != $.clearingHouseBalance) {
      if (actualClearingHouseBalance > $.clearingHouseBalance) {
        // Profit
        uint256 profit = actualClearingHouseBalance - $.clearingHouseBalance;
        $.utilizedAssets += profit;
      } else {
        // Loss
        uint256 loss = $.clearingHouseBalance - actualClearingHouseBalance;
        if (loss >= $.utilizedAssets) {
          $.utilizedAssets = 0;
        } else {
          $.utilizedAssets -= loss;
        }
      }

      $.clearingHouseBalance = actualClearingHouseBalance;
    }

    require(amount <= $.utilizedAssets, "Amount exceeds utilized assets");

    // Withdraw from ClearingHouse
    $.baseVolManager.withdrawFromClearingHouse(amount, address(this));
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
      $.clearingHouseBalance += amount;

      emit Utilize(_msgSender(), amount, 0);
    }

    // Reset to IDLE after completion
    _setStrategyStatus(StrategyStatus.IDLE);
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
      uint256 actualClearingHouseBalance = $.baseVolManager.getClearingHouseBalance();

      // Update utilizedAssets considering profit or loss
      if (actualClearingHouseBalance != $.clearingHouseBalance) {
        if (actualClearingHouseBalance > $.clearingHouseBalance) {
          // Profit
          uint256 profit = actualClearingHouseBalance - $.clearingHouseBalance;
          $.utilizedAssets += profit;
        } else {
          // Loss
          uint256 loss = $.clearingHouseBalance - actualClearingHouseBalance;
          if (loss >= $.utilizedAssets) {
            $.utilizedAssets = 0;
          } else {
            $.utilizedAssets -= loss;
          }
        }
        $.clearingHouseBalance = actualClearingHouseBalance;
      }

      // Transfer assets back to Vault
      IERC20 _asset = $.asset;
      _asset.safeTransfer(address(vault()), amount);

      // Update state
      $.utilizedAssets -= amount;
      $.clearingHouseBalance -= amount;

      emit Deutilize(_msgSender(), 0, amount);
    }

    // Reset to IDLE after completion
    _setStrategyStatus(StrategyStatus.IDLE);
  }

  /*//////////////////////////////////////////////////////////////
                            KEEPER LOGIC   
    //////////////////////////////////////////////////////////////*/

  /// @notice Processes idle assets for the withdraw requests.
  /// @dev Callable by anyone and only when strategy is in the IDLE status.
  function processAssetsToWithdraw() public whenIdle {
    address _asset = asset();
    uint256 _assetsToWithdraw = assetsToWithdraw();

    if (_assetsToWithdraw > 0) {
      IERC20(_asset).safeTransfer(vault(), _assetsToWithdraw);
    }
  }

  /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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
    GenesisStrategyStorage.Layout storage $ = GenesisStrategyStorage.layout();
    _setStrategyStatus(StrategyStatus.DEUTILIZING);

    // Deutilize all assets
    if ($.utilizedAssets > 0) {
      _deutilize($.utilizedAssets);
    }

    _pause();
    emit Stopped(_msgSender());
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

  function _resetToIdle() internal {
    _setStrategyStatus(StrategyStatus.IDLE);
  }

  /*//////////////////////////////////////////////////////////////
                        STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

  /// @notice The address of connected vault.
  function vault() public view returns (address) {
    return address(GenesisStrategyStorage.layout().vault);
  }

  /// @notice The address of the BaseVolManager.
  function baseVolManager() public view returns (address) {
    return address(GenesisStrategyStorage.layout().baseVolManager);
  }

  /// @notice The address of the ClearingHouse.
  function clearingHouse() public view returns (address) {
    return address(GenesisStrategyStorage.layout().clearingHouse);
  }

  /// @notice The address of operator which is responsible for calling utilize/deutilize.
  function operator() public view returns (address) {
    return GenesisStrategyStorage.layout().operator;
  }

  /// @notice The address of underlying asset.
  function asset() public view returns (address) {
    return address(GenesisStrategyStorage.layout().asset);
  }

  /// @notice The strategy status.
  function strategyStatus() public view returns (StrategyStatus) {
    return GenesisStrategyStorage.layout().strategyStatus;
  }

  function maxUtilizePct() public view returns (uint256) {
    return GenesisStrategyStorage.layout().maxUtilizePct;
  }

  /// @notice The amount of assets currently utilized.
  function utilizedAssets() public view returns (uint256) {
    return GenesisStrategyStorage.layout().utilizedAssets;
  }

  /// @notice The current ClearingHouse balance for this strategy.
  function clearingHouseBalance() public view returns (uint256) {
    return GenesisStrategyStorage.layout().clearingHouseBalance;
  }

  /// @notice The amount of assets that need to be withdrawn to process withdraw requests.
  function assetsToWithdraw() public view returns (uint256) {
    return IERC20(asset()).balanceOf(address(this));
  }
}
