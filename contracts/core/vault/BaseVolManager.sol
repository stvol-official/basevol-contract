// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IClearingHouse } from "../../interfaces/IClearingHouse.sol";
import { IGenesisVault } from "./interfaces/IGenesisVault.sol";
import { IGenesisStrategy } from "./interfaces/IGenesisStrategy.sol";
import { BaseVolManagerStorage } from "./storage/BaseVolManagerStorage.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

contract BaseVolManager is
  Initializable,
  UUPSUpgradeable,
  PausableUpgradeable,
  OwnableUpgradeable,
  ReentrancyGuardUpgradeable
{
  using SafeERC20 for IERC20;
  using Strings for uint256;

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
  event DebugLog(string message);

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

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(address _clearingHouse, address _strategy) external initializer {
    __UUPSUpgradeable_init();
    __Ownable_init(msg.sender);
    __Pausable_init();
    __ReentrancyGuard_init();

    address _asset = IGenesisStrategy(_strategy).asset();
    BaseVolManagerStorage.Layout storage $ = BaseVolManagerStorage.layout();

    require(_clearingHouse != address(0), "Invalid ClearingHouse address");

    $.asset = IERC20(_asset);
    $.clearingHouse = IClearingHouse(_clearingHouse);
    $.strategy = _strategy;

    // Set default configuration
    $.maxStrategyDeposit = 1000000e6; // 1M USDC
    $.minStrategyDeposit = 10e6; // 10 USDC
    $.maxTotalExposure = 10000000e6; // 10M USDC

    // Approve USDC spending for ClearingHouse and Strategy
    $.asset.approve(_clearingHouse, type(uint256).max);
    $.asset.approve(_strategy, type(uint256).max);
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

    // Check if total exposure would exceed limit
    if ($.totalUtilized + amount > $.maxTotalExposure) revert ExceedsMaxExposure();

    try $.clearingHouse.baseVolManagerDeposit(amount) {
      // Update global state
      $.totalDeposited += amount;
      $.totalUtilized += amount;
      emit DepositedToClearingHouse(
        $.strategy,
        amount,
        $.clearingHouse.userBalances(address(this))
      );
      // Call strategy callback on success
      IGenesisStrategy($.strategy).baseVolDepositCompletedCallback(amount, true);
    } catch {
      // Failure - call strategy callback on failure
      IGenesisStrategy($.strategy).baseVolDepositCompletedCallback(amount, false);
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

    uint256 availableBalance = $.clearingHouse.userBalances(address(this));
    if (availableBalance < amount) revert InsufficientBalance();

    try $.clearingHouse.baseVolManagerWithdraw(amount) {
      // Safe decrease to prevent underflow
      if ($.totalUtilized >= amount) {
        $.totalUtilized -= amount;
      } else {
        $.totalUtilized = 0;
      }

      emit WithdrawnFromClearingHouse(
        address($.strategy),
        amount,
        $.clearingHouse.userBalances(address(this))
      );

      // Check actual balance before transfer
      IERC20 _asset = $.asset;
      uint256 actualBalance = _asset.balanceOf(address(this));
      uint256 transferAmount = amount > actualBalance ? actualBalance : amount;

      if (transferAmount < amount) {
        emit DebugLog(
          string(
            abi.encodePacked(
              "Warning: BaseVolManager balance insufficient. Expected: ",
              amount.toString(),
              ", Available: ",
              actualBalance.toString()
            )
          )
        );
      }

      // Transfer available amount to strategy
      if (transferAmount > 0) {
        _asset.safeTransfer(strategy(), transferAmount);
      }

      // Call strategy callback with actual transferred amount
      IGenesisStrategy($.strategy).baseVolWithdrawCompletedCallback(transferAmount, true);
    } catch {
      // Failure - call strategy callback on failure
      IGenesisStrategy($.strategy).baseVolWithdrawCompletedCallback(0, false);
      revert("Withdraw from ClearingHouse failed");
    }
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

  /// @notice Emergency withdrawal for a strategy (owner only)
  /// @param amount The amount to withdraw
  function emergencyWithdraw(uint256 amount) external onlyOwner nonReentrant {
    BaseVolManagerStorage.Layout storage $ = BaseVolManagerStorage.layout();

    // Withdraw from ClearingHouse
    try $.clearingHouse.baseVolManagerWithdraw(amount) {
      // Safe decrease to prevent underflow
      if ($.totalUtilized >= amount) {
        $.totalUtilized -= amount;
      } else {
        $.totalUtilized = 0;
      }

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

    // Revoke approval from old ClearingHouse
    $.asset.approve(oldClearingHouse, 0);

    // Approve new ClearingHouse
    $.asset.approve(newClearingHouse, type(uint256).max);

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

  /// @notice Gets the total ClearingHouse balance including escrowed funds (for share price calculation)
  function totalClearingHouseBalance() public view returns (uint256) {
    return BaseVolManagerStorage.layout().clearingHouse.totalUserBalances(address(this));
  }

  /// @notice Gets the withdrawable ClearingHouse balance (for withdrawal operations)
  function withdrawableClearingHouseBalance() public view returns (uint256) {
    return BaseVolManagerStorage.layout().clearingHouse.userBalances(address(this));
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
