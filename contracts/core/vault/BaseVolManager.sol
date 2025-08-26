// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IClearingHouse } from "../../interfaces/IClearingHouse.sol";
import { IGenesisVault } from "./interfaces/IGenesisVault.sol";
import { IGenesisStrategy } from "./interfaces/IGenesisStrategy.sol";
import { BaseVolManagerStorage, StrategyInfo, AssetAllocation } from "./storage/BaseVolManagerStorage.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

contract BaseVolManager is
  Initializable,
  Ownable2StepUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable
{
  using SafeERC20 for IERC20;

  /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

  event DepositedToClearingHouse(
    address indexed strategy,
    uint256 amount,
    uint256 clearingHouseBalance
  );
  event WithdrawnFromClearingHouse(
    address indexed strategy,
    uint256 amount,
    uint256 clearingHouseBalance
  );
  event StrategyRegistered(address indexed strategy);
  event StrategyDeactivated(address indexed strategy);
  event AssetRebalanced(uint256 totalAllocated, uint256 totalUtilized);
  event ClearingHouseUpdated(address indexed oldClearingHouse, address indexed newClearingHouse);
  event VaultUpdated(address indexed oldVault, address indexed newVault);
  event ConfigUpdated(
    uint256 maxStrategyDeposit,
    uint256 minStrategyDeposit,
    uint256 maxTotalExposure
  );

  /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

  error InsufficientBalance();
  error InvalidAmount();
  error InvalidStrategy();
  error StrategyNotActive();
  error ExceedsMaxDeposit();
  error BelowMinDeposit();
  error ExceedsMaxExposure();
  error RebalanceNotNeeded();
  error InsufficientVaultBalance();

  /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

  constructor() {
    _disableInitializers();
  }

  function initialize(
    address _asset,
    address _clearingHouse,
    address _vault,
    address _owner
  ) external initializer {
    __Ownable_init(_owner);
    __Pausable_init();
    __ReentrancyGuard_init();

    BaseVolManagerStorage.Layout storage $ = BaseVolManagerStorage.layout();

    require(_asset != address(0), "Invalid asset address");
    require(_clearingHouse != address(0), "Invalid ClearingHouse address");
    require(_vault != address(0), "Invalid Vault address");

    $.asset = IERC20(_asset);
    $.clearingHouse = IClearingHouse(_clearingHouse);
    $.vault = IGenesisVault(_vault);

    // Set default configuration
    $.maxStrategyDeposit = 1000000e6; // 1M USDC
    $.minStrategyDeposit = 10e6; // 10 USDC
    $.maxTotalExposure = 10000000e6; // 10M USDC
  }

  /*//////////////////////////////////////////////////////////////
                        CLEARINGHOUSE ASSET MANAGEMENT
    //////////////////////////////////////////////////////////////*/

  /// @notice Deposits assets from Strategy to ClearingHouse
  /// @param amount The amount of assets to deposit
  function depositToClearingHouse(
    uint256 amount,
    address strategy
  ) external nonReentrant whenNotPaused {
    if (amount == 0) revert InvalidAmount();
    if (amount < BaseVolManagerStorage.layout().minStrategyDeposit) revert BelowMinDeposit();
    if (amount > BaseVolManagerStorage.layout().maxStrategyDeposit) revert ExceedsMaxDeposit();

    BaseVolManagerStorage.Layout storage $ = BaseVolManagerStorage.layout();

    // Check if total exposure would exceed limit
    if ($.totalUtilized + amount > $.maxTotalExposure) revert ExceedsMaxExposure();

    // Transfer assets from Strategy to BaseVolManager
    $.asset.safeTransferFrom(msg.sender, address(this), amount);

    // Approve ClearingHouse to spend assets
    $.asset.approve(address($.clearingHouse), amount);

    try $.clearingHouse.baseVolManagerDepositCallback(amount) {
      // Success - update strategy info
      StrategyInfo storage strategyInfo = $.strategies[strategy];
      if (!strategyInfo.isActive) {
        strategyInfo.strategy = strategy;
        strategyInfo.isActive = true;
        $.activeStrategies.push(strategy);
        $.activeStrategyCount++;
        emit StrategyRegistered(strategy);
      }

      strategyInfo.totalDeposited += amount;
      strategyInfo.currentBalance += amount;
      strategyInfo.lastActivity = block.timestamp;

      // Update global state
      $.totalDeposited += amount;
      $.totalUtilized += amount;
      $.assetAllocation.totalAllocated += amount;
      $.assetAllocation.totalUtilized += amount;

      emit DepositedToClearingHouse(strategy, amount, $.clearingHouse.userBalances(address(this)));

      // Call strategy callback on success
      IGenesisStrategy(strategy).depositCompletedCallback(amount, true);
    } catch {
      // Failure - call strategy callback on failure
      IGenesisStrategy(strategy).depositCompletedCallback(amount, false);
      revert("Deposit to ClearingHouse failed");
    }
  }

  /// @notice Withdraws assets from ClearingHouse back to Strategy
  /// @param amount The amount of assets to withdraw
  /// @param strategy The address of the strategy requesting withdrawal
  function withdrawFromClearingHouse(
    uint256 amount,
    address strategy
  ) external nonReentrant whenNotPaused {
    if (amount == 0) revert InvalidAmount();

    BaseVolManagerStorage.Layout storage $ = BaseVolManagerStorage.layout();

    // Validate strategy
    StrategyInfo storage strategyInfo = $.strategies[strategy];
    require(strategyInfo.isActive, "Strategy not active");
    require(strategyInfo.currentBalance >= amount, "Insufficient balance");

    try $.clearingHouse.baseVolManagerWithdrawCallback(amount) {
      // Success - update strategy info
      strategyInfo.currentBalance -= amount;
      strategyInfo.lastActivity = block.timestamp;

      // Update global state
      $.totalUtilized -= amount;
      $.assetAllocation.totalUtilized -= amount;

      emit WithdrawnFromClearingHouse(
        strategy,
        amount,
        $.clearingHouse.userBalances(address(this))
      );

      // Call strategy callback on success
      IGenesisStrategy(strategy).withdrawCompletedCallback(amount, true);
    } catch {
      // Failure - call strategy callback on failure
      IGenesisStrategy(strategy).withdrawCompletedCallback(amount, false);
      revert("Withdraw from ClearingHouse failed");
    }
  }

  /// @notice Emergency withdrawal for a strategy (owner only)
  /// @param strategy The strategy address
  /// @param amount The amount to withdraw
  function emergencyWithdraw(address strategy, uint256 amount) external onlyOwner nonReentrant {
    BaseVolManagerStorage.Layout storage $ = BaseVolManagerStorage.layout();

    StrategyInfo storage strategyInfo = $.strategies[strategy];
    if (!strategyInfo.isActive) revert StrategyNotActive();

    // Withdraw from ClearingHouse
    $.clearingHouse.withdraw(address(this), amount);

    // Transfer to owner (for safety)
    $.asset.safeTransfer(owner(), amount);

    // Update state
    strategyInfo.currentBalance -= amount;
    $.totalUtilized -= amount;
    $.assetAllocation.totalUtilized -= amount;

    emit WithdrawnFromClearingHouse(strategy, amount, $.clearingHouse.userBalances(address(this)));
  }

  /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

  /// @notice Sets the ClearingHouse address
  function setClearingHouse(address newClearingHouse) external onlyOwner {
    require(newClearingHouse != address(0), "Invalid address");

    BaseVolManagerStorage.Layout storage $ = BaseVolManagerStorage.layout();
    address oldClearingHouse = address($.clearingHouse);
    $.clearingHouse = IClearingHouse(newClearingHouse);

    emit ClearingHouseUpdated(oldClearingHouse, newClearingHouse);
  }

  /// @notice Sets the Vault address
  function setVault(address newVault) external onlyOwner {
    require(newVault != address(0), "Invalid address");

    BaseVolManagerStorage.Layout storage $ = BaseVolManagerStorage.layout();
    address oldVault = address($.vault);
    $.vault = IGenesisVault(newVault);

    emit VaultUpdated(oldVault, newVault);
  }

  /// @notice Sets configuration parameters
  function setConfig(
    uint256 _maxStrategyDeposit,
    uint256 _minStrategyDeposit,
    uint256 _maxTotalExposure
  ) external onlyOwner {
    BaseVolManagerStorage.Layout storage $ = BaseVolManagerStorage.layout();

    $.maxStrategyDeposit = _maxStrategyDeposit;
    $.minStrategyDeposit = _minStrategyDeposit;
    $.maxTotalExposure = _maxTotalExposure;

    emit ConfigUpdated(_maxStrategyDeposit, _minStrategyDeposit, _maxTotalExposure);
  }

  /// @notice Deactivates a strategy
  function deactivateStrategy(address strategy) external onlyOwner {
    BaseVolManagerStorage.Layout storage $ = BaseVolManagerStorage.layout();
    StrategyInfo storage strategyInfo = $.strategies[strategy];

    if (strategyInfo.isActive) {
      strategyInfo.isActive = false;

      // Remove from active strategies array
      for (uint256 i = 0; i < $.activeStrategies.length; i++) {
        if ($.activeStrategies[i] == strategy) {
          $.activeStrategies[i] = $.activeStrategies[$.activeStrategies.length - 1];
          $.activeStrategies.pop();
          break;
        }
      }
      $.activeStrategyCount--;

      emit StrategyDeactivated(strategy);
    }
  }

  /// @notice Pauses the contract
  function pause() external onlyOwner {
    _pause();
  }

  /// @notice Unpauses the contract
  function unpause() external onlyOwner {
    _unpause();
  }

  /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

  /// @notice Gets the current ClearingHouse balance for this manager
  function getClearingHouseBalance() external view returns (uint256) {
    return BaseVolManagerStorage.layout().clearingHouse.userBalances(address(this));
  }

  /// @notice Gets strategy information
  function getStrategyInfo(address strategy) external view returns (StrategyInfo memory) {
    return BaseVolManagerStorage.layout().strategies[strategy];
  }

  /// @notice Gets all active strategies
  function getActiveStrategies() external view returns (address[] memory) {
    return BaseVolManagerStorage.layout().activeStrategies;
  }

  /// @notice Gets asset allocation information
  function getAssetAllocation() external view returns (AssetAllocation memory) {
    return BaseVolManagerStorage.layout().assetAllocation;
  }

  /// @notice Gets the total deposited amount
  function getTotalDeposited() external view returns (uint256) {
    return BaseVolManagerStorage.layout().totalDeposited;
  }

  /// @notice Gets the total withdrawn amount
  function getTotalWithdrawn() external view returns (uint256) {
    return BaseVolManagerStorage.layout().totalWithdrawn;
  }

  /// @notice Gets the total utilized amount
  function getTotalUtilized() external view returns (uint256) {
    return BaseVolManagerStorage.layout().totalUtilized;
  }

  /// @notice Gets configuration parameters
  function getConfig()
    external
    view
    returns (uint256 maxStrategyDeposit, uint256 minStrategyDeposit, uint256 maxTotalExposure)
  {
    BaseVolManagerStorage.Layout storage $ = BaseVolManagerStorage.layout();
    return ($.maxStrategyDeposit, $.minStrategyDeposit, $.maxTotalExposure);
  }
}
