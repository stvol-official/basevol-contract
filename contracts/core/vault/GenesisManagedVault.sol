// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { GenesisVaultManagedVaultStorage } from "./storage/GenesisVaultManagedVaultStorage.sol";
import { IGenesisVaultErrors } from "./errors/GenesisVaultErrors.sol";

/// @title BaseVolManagedVault
///
/// @author BaseVol Team
///
/// @dev An abstract ERC4626 compliant vault with functions
/// to collect AUM fees including the management fee and performance fee.
abstract contract GenesisManagedVault is
  Initializable,
  UUPSUpgradeable,
  OwnableUpgradeable,
  PausableUpgradeable,
  ERC4626Upgradeable,
  IGenesisVaultErrors
{
  using Math for uint256;
  using SafeERC20 for IERC20;

  uint256 internal constant FLOAT_PRECISION = 1e18;

  /// @notice The maximum value of management fee that can be configured.
  uint256 private constant MAX_MANAGEMENT_FEE = 5e16; // 5%
  /// @notice The maximum value of performance fee that can be configured.
  uint256 private constant MAX_PERFORMANCE_FEE = 5e17; // 50%
  /// @notice The maximum value of entry/exit cost that can be configured (fixed amount).
  uint256 private constant MAX_FIXED_COST = 1000e6; // 1000 USDC (assuming 6 decimals)

  /// @dev Emitted when a new management fee configuration is set.
  event ManagementFeeChanged(address account, uint256 newManagementFee);

  /// @dev Emitted when a new performance fee configuration is set.
  event PerformanceFeeChanged(address account, uint256 newPerformanceFee);

  /// @dev Emitted when a new hurdle rate configuration is set.
  event HurdleRateChanged(address account, uint256 newHurdleRate);

  /// @dev Emitted when entry cost is updated
  event EntryCostUpdated(address account, uint256 newEntryCost);

  /// @dev Emitted when exit cost is updated
  event ExitCostUpdated(address account, uint256 newExitCost);

  /// @dev Emitted when fees are withdrawn
  event FeesWithdrawn(address indexed to, uint256 amount);

  /// @dev Emitted when performance fee is charged
  event PerformanceFeeCharged(
    address indexed user,
    uint256 feeAmount,
    uint256 currentSharePrice,
    uint256 userWAEP
  );

  /// @dev Emitted when management fee is processed
  event ManagementFeeProcessed(
    uint256 indexed feeShares,
    uint256 indexed totalSupply,
    uint256 indexed timeElapsed
  );

  /// @dev Emitted when a new deposit limit of each user is set.
  event UserDepositLimitChanged(
    address account,
    uint256 oldUserDepositLimit,
    uint256 newUserDepositLimit
  );

  /// @dev Emitted when a new deposit limit of a vault is set.
  event VaultDepositLimitChanged(
    address account,
    uint256 oldVaultDepositLimit,
    uint256 newVaultDepositLimit
  );

  /// @dev Emitted when a new admin is set.
  event AdminUpdated(address indexed account, address indexed oldAdmin, address indexed newAdmin);

  /// @dev Emitted when fee recipient is updated
  event FeeRecipientUpdated(
    address indexed account,
    address indexed oldRecipient,
    address indexed newRecipient
  );

  /// @dev Emitted when fees are transferred to recipient
  event FeesTransferred(address indexed recipient, uint256 amount, string feeType);

  /// @dev Modifier to restrict function access to admin only
  modifier onlyAdmin() {
    if (_msgSender() != admin()) {
      revert OnlyAdmin();
    }
    _;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function __GenesisManagedVault_init(
    address owner_,
    address admin_,
    address asset_,
    string calldata name_,
    string calldata symbol_
  ) internal onlyInitializing {
    __UUPSUpgradeable_init();
    __Ownable_init(owner_);
    __Pausable_init();
    __ERC20_init_unchained(name_, symbol_);
    __ERC4626_init_unchained(IERC20(asset_));
    GenesisVaultManagedVaultStorage.Layout storage $ = GenesisVaultManagedVaultStorage.layout();
    $.admin = admin_;
    _setDepositLimits(type(uint256).max, type(uint256).max);

    // Initialize management fee timestamp
    $.managementFeeData.lastFeeTimestamp = block.timestamp;
  }

  /* internal functions */
  function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

  function _setDepositLimits(uint256 userLimit, uint256 vaultLimit) internal {
    GenesisVaultManagedVaultStorage.Layout storage $ = GenesisVaultManagedVaultStorage.layout();
    if (userDepositLimit() != userLimit) {
      uint256 oldUserDepositLimit = $.userDepositLimit;
      $.userDepositLimit = userLimit;
      emit UserDepositLimitChanged(_msgSender(), oldUserDepositLimit, userLimit);
    }
    if (vaultDepositLimit() != vaultLimit) {
      uint256 oldVaultDepositLimit = $.vaultDepositLimit;
      $.vaultDepositLimit = vaultLimit;
      emit VaultDepositLimitChanged(_msgSender(), oldVaultDepositLimit, vaultLimit);
    }
  }

  /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

  /// @dev Configures the fee information.
  ///
  /// @param _managementFee The management fee percent that is denominated in 18 decimals.
  /// @param _performanceFee The performance fee percent that is denominated in 18 decimals.
  /// @param _hurdleRate The hurdle rate percent that is denominated in 18 decimals.
  function setFeeInfos(
    address _feeRecipient,
    uint256 _managementFee,
    uint256 _performanceFee,
    uint256 _hurdleRate
  ) external onlyAdmin {
    require(_managementFee <= MAX_MANAGEMENT_FEE);
    require(_performanceFee <= MAX_PERFORMANCE_FEE);

    GenesisVaultManagedVaultStorage.Layout storage $ = GenesisVaultManagedVaultStorage.layout();
    if ($.feeRecipient != _feeRecipient) {
      address oldFeeRecipient = $.feeRecipient;
      $.feeRecipient = _feeRecipient;
      emit FeeRecipientUpdated(_msgSender(), oldFeeRecipient, _feeRecipient);
    }
    if ($.managementFee != _managementFee) {
      $.managementFee = _managementFee;
      emit ManagementFeeChanged(_msgSender(), _managementFee);
    }
    if ($.performanceFee != _performanceFee) {
      $.performanceFee = _performanceFee;
      emit PerformanceFeeChanged(_msgSender(), _performanceFee);
    }
    if ($.hurdleRate != _hurdleRate) {
      $.hurdleRate = _hurdleRate;
      emit HurdleRateChanged(_msgSender(), _hurdleRate);
    }
  }

  /// @dev Configures entry and exit costs as fixed amounts.
  ///
  /// @param _entryCost The entry cost as a fixed amount in asset units.
  /// @param _exitCost The exit cost as a fixed amount in asset units.
  function setEntryAndExitCost(uint256 _entryCost, uint256 _exitCost) external virtual onlyAdmin {
    _setEntryCost(_entryCost);
    _setExitCost(_exitCost);
  }

  function _setEntryCost(uint256 value) internal {
    require(value <= MAX_FIXED_COST, "Entry cost exceeds maximum");
    if (entryCost() != value) {
      GenesisVaultManagedVaultStorage.layout().entryCost = value;
      emit EntryCostUpdated(_msgSender(), value);
    }
  }

  function _setExitCost(uint256 value) internal {
    require(value <= MAX_FIXED_COST, "Exit cost exceeds maximum");
    if (exitCost() != value) {
      GenesisVaultManagedVaultStorage.layout().exitCost = value;
      emit ExitCostUpdated(_msgSender(), value);
    }
  }

  /// @dev Sets the deposit limits including user and vault limit.
  function setDepositLimits(uint256 userLimit, uint256 vaultLimit) external onlyAdmin {
    _setDepositLimits(userLimit, vaultLimit);
  }

  function _calcFeeFraction(uint256 annualFee, uint256 duration) private pure returns (uint256) {
    return annualFee.mulDiv(duration, 365 days);
  }

  /// @dev Calculates the cost part of an amount `assets` that already includes cost.
  function _costOnTotal(uint256 assets, uint256 costRate) internal pure returns (uint256) {
    return assets.mulDiv(costRate, costRate + FLOAT_PRECISION, Math.Rounding.Ceil);
  }

  /// @dev Calculates fixed cost amount (returns the fixed cost directly)
  function _calculateFixedCost(uint256 fixedCost) internal pure returns (uint256) {
    return fixedCost;
  }

  /// @dev Updates user's WAEP on deposit
  /// @param user The user address
  /// @param newShares The amount of new shares being deposited
  /// @param currentSharePrice The current share price (scaled by share decimals)
  function _updateUserWAEP(address user, uint256 newShares, uint256 currentSharePrice) internal {
    GenesisVaultManagedVaultStorage.Layout storage $ = GenesisVaultManagedVaultStorage.layout();
    GenesisVaultManagedVaultStorage.UserPerformanceData storage userData = $.userPerformanceData[
      user
    ];

    uint256 currentShares = balanceOf(user) - newShares; // Shares before this deposit

    if (currentShares == 0) {
      // First deposit: WAEP = current share price
      userData.waep = currentSharePrice;
    } else {
      // Weighted average calculation
      // WAEP_new = (WAEP_prev × shares_prev + sharePrice_current × shares_new) / (shares_prev + shares_new)
      userData.waep =
        (userData.waep * currentShares + currentSharePrice * newShares) /
        (currentShares + newShares);
    }

    userData.totalShares = currentShares + newShares;
    userData.lastUpdateEpoch = block.timestamp; // Use block.timestamp as fallback
  }

  /// @dev Calculates and charges performance fee on withdrawal
  /// @param user The user address
  /// @param withdrawShares The amount of shares being withdrawn
  /// @param currentSharePrice The current share price (scaled by share decimals)
  /// @return feeAmount The performance fee amount in assets
  function _calculateAndChargePerformanceFee(
    address user,
    uint256 withdrawShares,
    uint256 currentSharePrice
  ) internal returns (uint256 feeAmount) {
    GenesisVaultManagedVaultStorage.Layout storage $ = GenesisVaultManagedVaultStorage.layout();
    GenesisVaultManagedVaultStorage.UserPerformanceData storage userData = $.userPerformanceData[
      user
    ];

    // WAEP not set (migration case)
    if (userData.waep == 0) {
      userData.waep = currentSharePrice; // Initialize with current price
      return 0; // No fee on first withdrawal after migration
    }

    // Calculate profit only if current price > WAEP
    if (currentSharePrice > userData.waep) {
      uint256 profitPerShare = currentSharePrice - userData.waep;
      uint256 totalProfit = (profitPerShare * withdrawShares) / (10 ** decimals());

      // Apply hurdle rate: only charge performance fee on profit above hurdle rate
      uint256 hurdleRateValue = hurdleRate();
      if (hurdleRateValue > 0) {
        // Calculate the hurdle rate threshold in terms of profit per share
        // hurdleRate is in 18 decimals, so we need to scale it properly
        uint256 hurdleThresholdPerShare = (userData.waep * hurdleRateValue) / FLOAT_PRECISION;

        // Only charge fee on profit above the hurdle threshold
        if (profitPerShare > hurdleThresholdPerShare) {
          uint256 excessProfitPerShare = profitPerShare - hurdleThresholdPerShare;
          uint256 excessProfit = (excessProfitPerShare * withdrawShares) / (10 ** decimals());

          // Calculate performance fee on excess profit only
          feeAmount = (excessProfit * performanceFee()) / FLOAT_PRECISION;
        }
        // If profit doesn't exceed hurdle rate, no performance fee
      } else {
        // No hurdle rate set, charge fee on all profit
        feeAmount = (totalProfit * performanceFee()) / FLOAT_PRECISION;
      }

      // Transfer fees immediately if any
      if (feeAmount > 0) {
        _transferFeesToRecipient(feeAmount, "performance");
        emit PerformanceFeeCharged(user, feeAmount, currentSharePrice, userData.waep);
      }
    }

    // Update user data (WAEP remains unchanged for withdrawals)
    userData.totalShares = balanceOf(user) - withdrawShares;

    return feeAmount;
  }

  /*//////////////////////////////////////////////////////////////
                            STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

  /// @notice Get fee recipient for all fees
  /// @return Address that receives all fees
  function feeRecipient() external view returns (address) {
    return GenesisVaultManagedVaultStorage.layout().feeRecipient;
  }
  /// @notice The management fee percent configuration denominated in 18 decimals.
  function managementFee() public view returns (uint256) {
    return GenesisVaultManagedVaultStorage.layout().managementFee;
  }

  /// @notice The performance fee percent configuration denominated in 18 decimals.
  function performanceFee() public view returns (uint256) {
    return GenesisVaultManagedVaultStorage.layout().performanceFee;
  }

  /// @notice The hurdle rate configuration denominated in 18 decimals.
  function hurdleRate() public view returns (uint256) {
    return GenesisVaultManagedVaultStorage.layout().hurdleRate;
  }

  /// @notice The allowed deposit limit of each user.
  function userDepositLimit() public view returns (uint256) {
    return GenesisVaultManagedVaultStorage.layout().userDepositLimit;
  }

  /// @notice The allowed deposit limit of this vault.
  function vaultDepositLimit() public view returns (uint256) {
    return GenesisVaultManagedVaultStorage.layout().vaultDepositLimit;
  }

  /// @notice The address of admin who is responsible for operational management.
  function admin() public view returns (address) {
    return GenesisVaultManagedVaultStorage.layout().admin;
  }

  /// @notice Configures the admin.
  ///
  /// @param account The address of new admin.
  /// A zero address means disabling admin functions.
  function setAdmin(address account) external onlyOwner {
    GenesisVaultManagedVaultStorage.Layout storage $ = GenesisVaultManagedVaultStorage.layout();
    address oldAdmin = $.admin;
    $.admin = account;
    emit AdminUpdated(_msgSender(), oldAdmin, account);
  }

  /// @notice The entry cost percent that is charged when depositing.
  ///
  /// @dev Denominated in 18 decimals.
  function entryCost() public view returns (uint256) {
    return GenesisVaultManagedVaultStorage.layout().entryCost;
  }

  /// @notice The exit cost percent that is charged when withdrawing.
  ///
  /// @dev Denominated in 18 decimals.
  function exitCost() public view returns (uint256) {
    return GenesisVaultManagedVaultStorage.layout().exitCost;
  }

  /// @notice Get user's WAEP data
  /// @param user The user address
  /// @return waep The user's weighted average entry price
  /// @return totalShares The user's total shares tracked
  /// @return lastUpdateEpoch The last epoch when data was updated
  function getUserPerformanceData(
    address user
  ) external view returns (uint256 waep, uint256 totalShares, uint256 lastUpdateEpoch) {
    GenesisVaultManagedVaultStorage.UserPerformanceData
      storage userData = GenesisVaultManagedVaultStorage.layout().userPerformanceData[user];
    return (userData.waep, userData.totalShares, userData.lastUpdateEpoch);
  }

  /// @notice Transfer fees immediately to fee recipient
  /// @param amount The amount of fees to transfer
  /// @param feeType The type of fee being transferred
  function _transferFeesToRecipient(uint256 amount, string memory feeType) internal {
    if (amount == 0) return;

    GenesisVaultManagedVaultStorage.Layout storage $ = GenesisVaultManagedVaultStorage.layout();
    address recipient = $.feeRecipient;

    // If no fee recipient set, skip transfer
    if (recipient == address(0)) {
      return;
    }

    // Transfer fees immediately to recipient
    IERC20(asset()).safeTransfer(recipient, amount);
    emit FeesTransferred(recipient, amount, feeType);
  }

  /*//////////////////////////////////////////////////////////////
                        MANAGEMENT FEE FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Get management fee data
  /// @return lastFeeTimestamp Last timestamp when fee was charged
  /// @return totalFeesCollected Total fees collected in shares
  /// @return feeRecipient Address that receives fees (now uses unified fee recipient)
  function getManagementFeeData()
    external
    view
    returns (uint256 lastFeeTimestamp, uint256 totalFeesCollected, address feeRecipient)
  {
    GenesisVaultManagedVaultStorage.Layout storage $ = GenesisVaultManagedVaultStorage.layout();
    GenesisVaultManagedVaultStorage.ManagementFeeData storage feeData = $.managementFeeData;
    return (feeData.lastFeeTimestamp, feeData.totalFeesCollected, $.feeRecipient);
  }

  /// @notice Internal function to mint management fee shares
  function _mintManagementFeeShares() internal {
    GenesisVaultManagedVaultStorage.Layout storage $ = GenesisVaultManagedVaultStorage.layout();
    GenesisVaultManagedVaultStorage.ManagementFeeData storage feeData = $.managementFeeData;

    uint256 currentTotalSupply = totalSupply();
    if (currentTotalSupply == 0) return;

    uint256 timeElapsed = block.timestamp - feeData.lastFeeTimestamp;
    if (timeElapsed == 0) return; // Same block, skip

    // Calculate fee rate based on elapsed time
    uint256 feeRate = _calcFeeFraction(managementFee(), timeElapsed);
    uint256 feeShares = (currentTotalSupply * feeRate) / FLOAT_PRECISION;

    if (feeShares == 0) {
      // Update timestamp even if no fee to prevent accumulation
      feeData.lastFeeTimestamp = block.timestamp;
      return;
    }

    // Determine recipient: use unified fee recipient, if not set, mint to vault itself
    address recipient = $.feeRecipient;
    if (recipient == address(0)) {
      recipient = address(this);
    }

    // Mint shares to recipient
    _mint(recipient, feeShares);

    // Update state
    feeData.lastFeeTimestamp = block.timestamp;
    feeData.totalFeesCollected += feeShares;

    emit ManagementFeeProcessed(feeShares, currentTotalSupply, timeElapsed);
  }
}
