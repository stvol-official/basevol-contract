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
import { MorphoVaultManagerStorage } from "./storage/MorphoVaultManagerStorage.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

contract MorphoVaultManager is
  Initializable,
  UUPSUpgradeable,
  PausableUpgradeable,
  OwnableUpgradeable,
  ReentrancyGuardUpgradeable
{
  using SafeERC20 for IERC20;
  using Strings for uint256;

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
  event DebugLog(string message);

  error InsufficientBalance();
  error InvalidAmount();
  error ExceedsMaxDeposit();
  error BelowMinDeposit();
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

  function initialize(address _morphoVault, address _strategy) external initializer {
    __UUPSUpgradeable_init();
    __Ownable_init(msg.sender);
    __Pausable_init();
    __ReentrancyGuard_init();

    address _asset = IGenesisStrategy(_strategy).asset();
    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();

    require(_morphoVault != address(0), "Invalid Morpho Vault address");
    require(_strategy != address(0), "Invalid Strategy address");

    $.asset = IERC20(_asset);
    $.morphoVault = IMetaMorphoV1_1(_morphoVault);
    $.strategy = _strategy;

    // Set default configuration
    $.maxStrategyDeposit = 10000000e6; // 10M USDC
    $.minStrategyDeposit = 100e6; // 100 USDC

    // Approve USDC spending for Morpho Vault
    $.asset.approve(_morphoVault, type(uint256).max);
  }

  /// @notice Deposits assets from Strategy to Morpho Vault
  /// @dev Strategy must transfer assets to this contract before calling this function
  /// @param amount The amount of assets to deposit
  function depositToMorpho(
    uint256 amount
  ) external authCaller(strategy()) nonReentrant whenNotPaused {
    if (amount == 0) revert InvalidAmount();
    if (amount < MorphoVaultManagerStorage.layout().minStrategyDeposit) revert BelowMinDeposit();
    if (amount > MorphoVaultManagerStorage.layout().maxStrategyDeposit) revert ExceedsMaxDeposit();

    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();

    // Verify that we have received the assets from strategy
    uint256 balance = $.asset.balanceOf(address(this));
    if (balance < amount) revert InsufficientBalance();

    try $.morphoVault.deposit(amount, address(this)) returns (uint256 shares) {
      // Update global state
      $.totalDeposited += amount;
      $.totalUtilized += amount;
      $.morphoShares += shares;

      emit DepositedToMorpho($.strategy, amount, shares, $.morphoVault.balanceOf(address(this)));

      // Call strategy callback on success
      IGenesisStrategy($.strategy).morphoDepositCompletedCallback(amount, true);
    } catch {
      // Failure - call strategy callback on failure
      IGenesisStrategy($.strategy).morphoDepositCompletedCallback(amount, false);
      revert("Deposit to Morpho failed");
    }
  }

  /// @notice Withdraws assets from Morpho Vault back to Strategy
  /// @param amount The amount of assets to withdraw
  function withdrawFromMorpho(
    uint256 amount
  ) external authCaller(strategy()) nonReentrant whenNotPaused {
    if (amount == 0) revert InvalidAmount();

    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();

    uint256 availableAssets = $.morphoVault.maxWithdraw(address(this));
    if (availableAssets < amount) revert InsufficientBalance();

    try $.morphoVault.withdraw(amount, address(this), address(this)) returns (uint256 shares) {
      $.totalUtilized -= amount;
      $.totalWithdrawn += amount;
      $.morphoShares -= shares;

      emit WithdrawnFromMorpho(
        address($.strategy),
        amount,
        shares,
        $.morphoVault.balanceOf(address(this))
      );

      // Check actual balance before transfer
      uint256 actualBalance = $.asset.balanceOf(address(this));
      uint256 transferAmount = amount > actualBalance ? actualBalance : amount;

      if (transferAmount < amount) {
        emit DebugLog(
          string(
            abi.encodePacked(
              "Warning: MorphoVaultManager balance insufficient. Expected: ",
              amount.toString(),
              ", Available: ",
              actualBalance.toString()
            )
          )
        );
      }

      // Transfer available amount to strategy
      if (transferAmount > 0) {
        $.asset.safeTransfer(strategy(), transferAmount);
      }

      // Call strategy callback with actual transferred amount
      IGenesisStrategy($.strategy).morphoWithdrawCompletedCallback(transferAmount, true);
    } catch {
      // Failure - call strategy callback on failure
      IGenesisStrategy($.strategy).morphoWithdrawCompletedCallback(amount, false);
      revert("Withdraw from Morpho failed");
    }
  }

  /// @notice Redeems shares from Morpho Vault
  /// @param shares The amount of shares to redeem
  function redeemFromMorpho(
    uint256 shares
  ) external authCaller(strategy()) nonReentrant whenNotPaused {
    if (shares == 0) revert InvalidAmount();

    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();

    uint256 availableShares = $.morphoVault.balanceOf(address(this));
    if (availableShares < shares) revert InsufficientBalance();

    try $.morphoVault.redeem(shares, address(this), address(this)) returns (uint256 assets) {
      $.totalUtilized -= assets;
      $.totalWithdrawn += assets;
      $.morphoShares -= shares;

      emit RedeemedFromMorpho(
        address($.strategy),
        shares,
        assets,
        $.morphoVault.balanceOf(address(this))
      );

      // Check actual balance before transfer
      uint256 actualBalance = $.asset.balanceOf(address(this));
      uint256 transferAmount = assets > actualBalance ? actualBalance : assets;

      if (transferAmount < assets) {
        emit DebugLog(
          string(
            abi.encodePacked(
              "Warning: MorphoVaultManager balance insufficient for redeem. Expected: ",
              assets.toString(),
              ", Available: ",
              actualBalance.toString()
            )
          )
        );
      }

      // Transfer available amount to strategy
      if (transferAmount > 0) {
        $.asset.safeTransfer(strategy(), transferAmount);
      }

      // Call strategy callback with actual transferred amount
      IGenesisStrategy($.strategy).morphoRedeemCompletedCallback(shares, transferAmount, true);
    } catch {
      // Failure - call strategy callback on failure
      IGenesisStrategy($.strategy).morphoRedeemCompletedCallback(shares, 0, false);
      revert("Redeem from Morpho failed");
    }
  }

  /// @notice Emergency withdrawal for a strategy (owner only)
  /// @param amount The amount to withdraw
  function emergencyWithdraw(uint256 amount) external onlyOwner nonReentrant {
    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();

    // Withdraw from Morpho Vault
    try $.morphoVault.withdraw(amount, owner(), address(this)) returns (uint256 shares) {
      $.totalUtilized -= amount;
      $.totalWithdrawn += amount;
      $.morphoShares -= shares;

      emit WithdrawnFromMorpho(strategy(), amount, shares, $.morphoVault.balanceOf(address(this)));
    } catch {
      revert("Emergency withdraw from Morpho failed");
    }
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

  /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

  /// @notice Sets configuration parameters
  function setConfig(uint256 _maxStrategyDeposit, uint256 _minStrategyDeposit) external onlyOwner {
    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();

    $.maxStrategyDeposit = _maxStrategyDeposit;
    $.minStrategyDeposit = _minStrategyDeposit;

    emit ConfigUpdated(_maxStrategyDeposit, _minStrategyDeposit);
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

  /// @notice Gets the Morpho Vault balance in assets
  function morphoAssetBalance() public view returns (uint256) {
    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();
    return $.morphoVault.convertToAssets($.morphoVault.balanceOf(address(this)));
  }

  /// @notice Gets the Morpho Vault balance in shares
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

  /// @notice Gets the current yield/profit from Morpho
  function currentYield() public view returns (uint256) {
    uint256 currentValue = morphoAssetBalance();
    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();
    uint256 invested = $.totalDeposited - $.totalWithdrawn;
    return currentValue > invested ? currentValue - invested : 0;
  }

  function config() public view returns (uint256 maxStrategyDeposit, uint256 minStrategyDeposit) {
    MorphoVaultManagerStorage.Layout storage $ = MorphoVaultManagerStorage.layout();
    return ($.maxStrategyDeposit, $.minStrategyDeposit);
  }

  function strategy() public view returns (address) {
    return MorphoVaultManagerStorage.layout().strategy;
  }

  function morphoVault() public view returns (address) {
    return address(MorphoVaultManagerStorage.layout().morphoVault);
  }
}
