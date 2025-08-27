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
import { BaseVolManagerStorage, AssetAllocation } from "./storage/BaseVolManagerStorage.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

contract BaseVolManager is
  Initializable,
  Ownable2StepUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable
{
  using SafeERC20 for IERC20;

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

  error InsufficientBalance();
  error InvalidAmount();
  error InvalidStrategy();
  error StrategyNotActive();
  error ExceedsMaxDeposit();
  error BelowMinDeposit();
  error ExceedsMaxExposure();
  error RebalanceNotNeeded();
  error InsufficientVaultBalance();
  error CallerNotAuthorized(address authorized, address caller);

  modifier authCaller(address authorized) {
    if (_msgSender() != authorized) {
      revert CallerNotAuthorized(authorized, _msgSender());
    }
    _;
  }

  constructor() {
    _disableInitializers();
  }

  function initialize(
    address _asset,
    address _clearingHouse,
    address _strategy,
    address _owner
  ) external initializer {
    __Ownable_init(_owner);
    __Pausable_init();
    __ReentrancyGuard_init();

    BaseVolManagerStorage.Layout storage $ = BaseVolManagerStorage.layout();

    require(_asset != address(0), "Invalid asset address");
    require(_clearingHouse != address(0), "Invalid ClearingHouse address");
    require(_strategy != address(0), "Invalid Strategy address");

    $.asset = IERC20(_asset);
    $.clearingHouse = IClearingHouse(_clearingHouse);
    $.strategy = _strategy;

    // Set default configuration
    $.maxStrategyDeposit = 1000000e6; // 1M USDC
    $.minStrategyDeposit = 10e6; // 10 USDC
    $.maxTotalExposure = 10000000e6; // 10M USDC
  }

  /// @notice Deposits assets from Strategy to ClearingHouse
  /// @param amount The amount of assets to deposit
  function depositToClearingHouse(
    uint256 amount
  ) external authCaller(strategy()) nonReentrant whenNotPaused {
    if (amount == 0) revert InvalidAmount();
    if (amount < BaseVolManagerStorage.layout().minStrategyDeposit) revert BelowMinDeposit();
    if (amount > BaseVolManagerStorage.layout().maxStrategyDeposit) revert ExceedsMaxDeposit();

    BaseVolManagerStorage.Layout storage $ = BaseVolManagerStorage.layout();

    // Only the registered strategy can call this function
    require(msg.sender == address($.strategy), "Only strategy can call");

    // Check if total exposure would exceed limit
    if ($.totalUtilized + amount > $.maxTotalExposure) revert ExceedsMaxExposure();

    // Transfer assets from Strategy to BaseVolManager
    $.asset.safeTransferFrom(msg.sender, address(this), amount);

    // Approve ClearingHouse to spend assets
    $.asset.approve(address($.clearingHouse), amount);

    try $.clearingHouse.baseVolManagerDepositCallback(amount) {
      // Update global state
      $.totalDeposited += amount;
      $.totalUtilized += amount;
      $.assetAllocation.totalAllocated += amount;
      $.assetAllocation.totalUtilized += amount;

      emit DepositedToClearingHouse(
        $.strategy,
        amount,
        $.clearingHouse.userBalances(address(this))
      );

      // Call strategy callback on success
      IGenesisStrategy($.strategy).depositCompletedCallback(amount, true);
    } catch {
      // Failure - call strategy callback on failure
      IGenesisStrategy($.strategy).depositCompletedCallback(amount, false);
      revert("Deposit to ClearingHouse failed");
    }
  }

  /// @notice Withdraws assets from ClearingHouse back to Strategy
  /// @param amount The amount of assets to withdraw
  function withdrawFromClearingHouse(
    uint256 amount
  ) external authCaller(strategy()) nonReentrant whenNotPaused {
    if (amount == 0) revert InvalidAmount();

    BaseVolManagerStorage.Layout storage $ = BaseVolManagerStorage.layout();

    // Only the registered strategy can call this function
    require(msg.sender == address($.strategy), "Only strategy can call");

    try $.clearingHouse.baseVolManagerWithdrawCallback(amount) {
      // Update global state
      $.totalUtilized -= amount;
      $.assetAllocation.totalUtilized -= amount;

      emit WithdrawnFromClearingHouse(
        address($.strategy),
        amount,
        $.clearingHouse.userBalances(address(this))
      );

      // Call strategy callback on success
      IGenesisStrategy($.strategy).withdrawCompletedCallback(amount, true);
    } catch {
      // Failure - call strategy callback on failure
      IGenesisStrategy($.strategy).withdrawCompletedCallback(amount, false);
      revert("Withdraw from ClearingHouse failed");
    }
  }

  /// @notice Emergency withdrawal for a strategy (owner only)
  /// @param amount The amount to withdraw
  function emergencyWithdraw(uint256 amount) external onlyOwner nonReentrant {
    BaseVolManagerStorage.Layout storage $ = BaseVolManagerStorage.layout();

    // Withdraw from ClearingHouse
    try $.clearingHouse.baseVolManagerWithdrawCallback(amount) {
      $.totalUtilized -= amount;
      $.assetAllocation.totalUtilized -= amount;

      emit WithdrawnFromClearingHouse(
        strategy(),
        amount,
        $.clearingHouse.userBalances(address(this))
      );
    } catch {
      revert("Withdraw from ClearingHouse failed");
    }

    // Transfer to owner (for safety)
    $.asset.safeTransfer(owner(), amount);
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

  /// @notice Pauses the contract
  function pause() external onlyOwner {
    _pause();
  }

  /// @notice Unpauses the contract
  function unpause() external onlyOwner {
    _unpause();
  }

  /// @notice Gets the current ClearingHouse balance for this manager
  function clearingHouseBalance() public view returns (uint256) {
    return BaseVolManagerStorage.layout().clearingHouse.userBalances(address(this));
  }

  function assetAllocation() public view returns (AssetAllocation memory) {
    return BaseVolManagerStorage.layout().assetAllocation;
  }

  function totalDeposited() public view returns (uint256) {
    return BaseVolManagerStorage.layout().totalDeposited;
  }

  function totalWithdrawn() public view returns (uint256) {
    return BaseVolManagerStorage.layout().totalWithdrawn;
  }

  function totalUtilized() public view returns (uint256) {
    return BaseVolManagerStorage.layout().totalUtilized;
  }

  function config()
    public
    view
    returns (uint256 maxStrategyDeposit, uint256 minStrategyDeposit, uint256 maxTotalExposure)
  {
    BaseVolManagerStorage.Layout storage $ = BaseVolManagerStorage.layout();
    return ($.maxStrategyDeposit, $.minStrategyDeposit, $.maxTotalExposure);
  }

  function strategy() public view returns (address) {
    return BaseVolManagerStorage.layout().strategy;
  }
}
