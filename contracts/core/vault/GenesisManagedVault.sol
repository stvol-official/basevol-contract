// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

  uint256 internal constant FLOAT_PRECISION = 1e18;

  /// @notice The maximum value of management fee that can be configured.
  uint256 private constant MAX_MANAGEMENT_FEE = 5e16; // 5%
  /// @notice The maximum value of performance fee that can be configured.
  uint256 private constant MAX_PERFORMANCE_FEE = 5e17; // 50%

  /// @dev Emitted when the management fee is collected to the fee recipient.
  event ManagementFeeCollected(address indexed feeRecipient, uint256 indexed feeShares);

  /// @dev Emitted when the performance fee is collected to the fee recipient.
  event PerformanceFeeCollected(address indexed feeRecipient, uint256 indexed feeShares);

  /// @dev Emitted when a new fee recipient is set.
  event FeeRecipientChanged(address account, address newFeeRecipient);

  /// @dev Emitted when a new management fee configuration is set.
  event ManagementFeeChanged(address account, uint256 newManagementFee);

  /// @dev Emitted when a new performance fee configuration is set.
  event PerformanceFeeChanged(address account, uint256 newPerformanceFee);

  /// @dev Emitted when a new hurdle rate configuration is set.
  event HurdleRateChanged(address account, uint256 newHurdleRate);

  /// @dev Emitted when a new deposit limit of each user is set.
  event UserDepositLimitChanged(address account, uint256 newUserDepositLimit);

  /// @dev Emitted when a new deposit limit of a vault is set.
  event VaultDepositLimitChanged(address account, uint256 newVaultDepositLimit);

  /// @dev Emitted when a new whitelist provider is set.
  event WhitelistProviderChanged(address account, address newWhitelistProvider);

  /// @dev Emitted when a new admin is set.
  event AdminUpdated(address indexed account, address indexed newAdmin);

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
    GenesisVaultManagedVaultStorage.layout().admin = admin_;
    _setDepositLimits(type(uint256).max, type(uint256).max);
  }

  /* internal functions */
  function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

  function _setDepositLimits(uint256 userLimit, uint256 vaultLimit) internal {
    GenesisVaultManagedVaultStorage.Layout storage $ = GenesisVaultManagedVaultStorage.layout();
    if (userDepositLimit() != userLimit) {
      $.userDepositLimit = userLimit;
      emit UserDepositLimitChanged(_msgSender(), userLimit);
    }
    if (vaultDepositLimit() != vaultLimit) {
      $.vaultDepositLimit = vaultLimit;
      emit VaultDepositLimitChanged(_msgSender(), vaultLimit);
    }
  }

  /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

  /// @dev Configures the fee information.
  ///
  /// @param _feeRecipient The address of the fee recipient.
  /// @param _managementFee The management fee percent that is denominated in 18 decimals.
  /// @param _performanceFee The performance fee percent that is denominated in 18 decimals.
  /// @param _hurdleRate The hurdle rate percent that is denominated in 18 decimals.
  function setFeeInfos(
    address _feeRecipient,
    uint256 _managementFee,
    uint256 _performanceFee,
    uint256 _hurdleRate
  ) external onlyAdmin {
    require(_feeRecipient != address(0));
    require(_managementFee <= MAX_MANAGEMENT_FEE);
    require(_performanceFee <= MAX_PERFORMANCE_FEE);
    _harvestPerformanceFeeShares();

    GenesisVaultManagedVaultStorage.Layout storage $ = GenesisVaultManagedVaultStorage.layout();
    if (feeRecipient() != _feeRecipient) {
      $.feeRecipient = _feeRecipient;
      emit FeeRecipientChanged(_msgSender(), _feeRecipient);
    }
    if (managementFee() != _managementFee) {
      $.managementFee = _managementFee;
      emit ManagementFeeChanged(_msgSender(), _managementFee);
    }
    if (performanceFee() != _performanceFee) {
      $.performanceFee = _performanceFee;
      emit PerformanceFeeChanged(_msgSender(), _performanceFee);
    }
    if (hurdleRate() != _hurdleRate) {
      $.hurdleRate = _hurdleRate;
      emit HurdleRateChanged(_msgSender(), _hurdleRate);
    }
  }

  /// @dev Sets the address of the whitelist provider.
  ///
  /// @param provider Address of the whitelist provider, address(0) means not applying whitelist.
  function setWhitelistProvider(address provider) external onlyOwner {
    if (whitelistProvider() != provider) {
      GenesisVaultManagedVaultStorage.layout().whitelistProvider = provider;
      emit WhitelistProviderChanged(_msgSender(), provider);
    }
  }

  /// @dev Sets the deposit limits including user and vault limit.
  function setDepositLimits(uint256 userLimit, uint256 vaultLimit) external onlyAdmin {
    _setDepositLimits(userLimit, vaultLimit);
  }

  /*//////////////////////////////////////////////////////////////
                        ERC4626 LOGIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

  /// @inheritdoc ERC4626Upgradeable
  function maxDeposit(address receiver) public view virtual override returns (uint256) {
    uint256 _userDepositLimit = userDepositLimit();
    uint256 _vaultDepositLimit = vaultDepositLimit();

    if (_userDepositLimit == type(uint256).max && _vaultDepositLimit == type(uint256).max) {
      return type(uint256).max;
    } else {
      uint256 userShares = balanceOf(receiver);
      uint256 userAssets = convertToAssets(userShares);
      (, uint256 availableDepositorLimit) = _userDepositLimit.trySub(userAssets);
      (, uint256 availableVaultLimit) = _vaultDepositLimit.trySub(totalAssets());
      uint256 allowed = availableDepositorLimit < availableVaultLimit
        ? availableDepositorLimit
        : availableVaultLimit;
      return allowed;
    }
  }

  /// @inheritdoc ERC4626Upgradeable
  function maxMint(address receiver) public view virtual override returns (uint256) {
    uint256 maxAssets = maxDeposit(receiver);
    return maxAssets == type(uint256).max ? type(uint256).max : previewDeposit(maxAssets);
  }

  /// @inheritdoc ERC4626Upgradeable
  function _convertToShares(
    uint256 assets,
    Math.Rounding rounding
  ) internal view override returns (uint256) {
    return
      assets.mulDiv(
        _totalSupplyWithManagementFeeShares(feeRecipient()) + 10 ** _decimalsOffset(),
        totalAssets() + 1,
        rounding
      );
  }

  /// @inheritdoc ERC4626Upgradeable
  function _convertToAssets(
    uint256 shares,
    Math.Rounding rounding
  ) internal view override returns (uint256) {
    return
      shares.mulDiv(
        totalAssets() + 1,
        _totalSupplyWithManagementFeeShares(feeRecipient()) + 10 ** _decimalsOffset(),
        rounding
      );
  }

  /// @dev Harvests the performance fee when it is available.
  ///
  /// @inheritdoc ERC4626Upgradeable
  function _deposit(
    address caller,
    address receiver,
    uint256 assets,
    uint256 shares
  ) internal virtual override {
    _updateHwmDeposit(assets);
    super._deposit(caller, receiver, assets, shares);
  }

  /// @dev Harvests the performance fee when it is available.
  ///
  /// @inheritdoc ERC4626Upgradeable
  function _withdraw(
    address caller,
    address receiver,
    address owner,
    uint256 assets,
    uint256 shares
  ) internal virtual override {
    _updateHwmWithdraw(shares);
    super._withdraw(caller, receiver, owner, assets, shares);
  }

  /// @dev Accrues the management fee when it is set.
  ///
  /// @inheritdoc ERC20Upgradeable
  function _update(address from, address to, uint256 value) internal override(ERC20Upgradeable) {
    address _feeRecipient = feeRecipient();
    address _whitelistProvider = whitelistProvider();

    if (to != address(0) && to != _feeRecipient && _whitelistProvider != address(0)) {
      revert NotWhitelisted(to);
    }

    if (_feeRecipient != address(0)) {
      if (
        (from == _feeRecipient && to != address(0)) || (from != address(0) && to == _feeRecipient)
      ) {
        revert ManagementFeeTransfer(_feeRecipient);
      }

      if (from != address(0) || to != _feeRecipient) {
        // called when minting to none of recipient
        // to stop infinite loop
        _accrueManagementFeeShares(_feeRecipient);
      }
    }

    super._update(from, to, value);
  }

  /*//////////////////////////////////////////////////////////////
                           FEE LOGIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

  function _harvestPerformanceFeeShares() internal {
    address _feeRecipient = feeRecipient();
    uint256 _performanceFee = performanceFee();
    uint256 _hwm = highWaterMark();
    uint256 _totalAssets = totalAssets();
    uint256 totalSupplyWithManagementFeeShares = _totalSupplyWithManagementFeeShares(_feeRecipient);
    uint256 _lastHarvestedTimestamp = lastHarvestedTimestamp();
    uint256 feeShares = _calcPerformanceFeeShares(
      _performanceFee,
      _hwm,
      _totalAssets,
      totalSupplyWithManagementFeeShares,
      _lastHarvestedTimestamp
    );

    // reset performance fee calculation
    uint256 newHwm = _totalAssets > _hwm ? _totalAssets : _hwm;
    GenesisVaultManagedVaultStorage.layout().lastHarvestedTimestamp = block.timestamp;
    GenesisVaultManagedVaultStorage.layout().hwm = newHwm;

    // mint performance fee shares
    if (feeShares > 0) {
      _mint(_feeRecipient, feeShares);
      emit PerformanceFeeCollected(_feeRecipient, feeShares);
    }
  }

  /// @dev Should be called whenever a deposit is made
  function _updateHwmDeposit(uint256 assets) internal {
    GenesisVaultManagedVaultStorage.layout().hwm = highWaterMark() + assets;
  }

  /// @dev Should be called before all withdrawals
  function _updateHwmWithdraw(uint256 shares) internal {
    uint256 oldTotalSupply = _totalSupplyWithManagementFeeShares(feeRecipient());
    GenesisVaultManagedVaultStorage.layout().hwm = highWaterMark().mulDiv(
      oldTotalSupply - shares,
      oldTotalSupply,
      Math.Rounding.Ceil
    );
  }

  /// @dev Should not be called when minting to fee recipient
  function _accrueManagementFeeShares(address _feeRecipient) private {
    uint256 _lastAccruedTimestamp = lastAccruedTimestamp();
    if (_lastAccruedTimestamp == block.timestamp) {
      // management fee must be 0, don't need to go through logic
      return;
    }
    uint256 _managementFee = managementFee();
    uint256 feeShares = _nextManagementFeeShares(
      _feeRecipient,
      _managementFee,
      totalSupply(),
      _lastAccruedTimestamp
    );
    if (_managementFee == 0 || _lastAccruedTimestamp == 0) {
      // update lastAccruedTimestamp to accrue management fee only after fee is set
      // when it is set, initialize it when lastAccruedTimestamp is 0
      GenesisVaultManagedVaultStorage.layout().lastAccruedTimestamp = block.timestamp;
    } else if (feeShares > 0) {
      // only when feeShares is bigger than 0 when managementFee is set as none-zero,
      // update lastAccruedTimestamp to mitigate DOS of management fee accruing
      _mint(_feeRecipient, feeShares);
      GenesisVaultManagedVaultStorage.layout().lastAccruedTimestamp = block.timestamp;
      emit ManagementFeeCollected(_feeRecipient, feeShares);
    }
  }

  /// @dev Calculates the claimable shares for the management fee
  function _nextManagementFeeShares(
    address _feeRecipient,
    uint256 _managementFee,
    uint256 _totalSupply,
    uint256 _lastAccruedTimestamp
  ) private view returns (uint256) {
    if (_managementFee == 0 || _lastAccruedTimestamp == 0) return 0;
    uint256 duration = block.timestamp - _lastAccruedTimestamp;
    if (duration == 0) return 0;
    uint256 accruedFee = _calcFeeFraction(_managementFee, duration);
    // should accrue fees regarding to other's shares except for feeRecipient
    uint256 shares = _totalSupply - balanceOf(_feeRecipient);
    // should be rounded to bottom to stop generating 1 shares by calling accrueManagementFeeShares function
    uint256 managementFeeShares = shares.mulDiv(accruedFee, FLOAT_PRECISION);
    return managementFeeShares;
  }

  /// @dev Calculates the claimable performance fee shares
  function _calcPerformanceFeeShares(
    uint256 _performanceFee,
    uint256 _hwm,
    uint256 _totalAssets,
    uint256 _totalSupply,
    uint256 _lastHarvestedTimestamp
  ) private view returns (uint256) {
    if (_performanceFee == 0 || _hwm == 0 || _lastHarvestedTimestamp == 0 || _totalAssets <= _hwm) {
      return 0;
    }
    uint256 profit = _totalAssets - _hwm;
    uint256 hurdleRateFraction = _calcFeeFraction(
      hurdleRate(),
      block.timestamp - _lastHarvestedTimestamp
    );
    uint256 hurdle = _hwm.mulDiv(hurdleRateFraction, FLOAT_PRECISION);
    if (profit > hurdle) {
      uint256 feeAssets = profit.mulDiv(_performanceFee, FLOAT_PRECISION);
      // we guarantee that user's profit is not less than hurdle
      if (profit - feeAssets < hurdle) {
        feeAssets = profit - hurdle;
      }
      // feeAssets = previewRedeem(feeShares)
      // previewRedeem = shares.mulDiv(totalAssets + 1, totalSupply + 10 ** _decimalsOffset, Math.Rounding.Floor);
      // feeAssets = feeShares.mulDiv(totalAssets + 1, (totalSupplyBeforeFeeMint + feeShares) + 10 ** _decimalsOffset, Math.Rounding.Floor);
      // feeShares = feeAssets.mulDiv(totalSupplyBeforeFeeMint + 10 ** _decimalsOffset, totalAssets + 1 - feeAssets, Math.Rounding.Ceil);
      uint256 feeShares = feeAssets.mulDiv(
        _totalSupply + 10 ** _decimalsOffset(),
        _totalAssets + 1 - feeAssets,
        Math.Rounding.Ceil
      );
      return feeShares;
    } else {
      return 0;
    }
  }

  /// @dev The total supply of shares including the next management fee shares.
  function _totalSupplyWithManagementFeeShares(
    address _feeRecipient
  ) private view returns (uint256) {
    uint256 _totalSupply = totalSupply();
    return
      _totalSupply +
      _nextManagementFeeShares(
        _feeRecipient,
        managementFee(),
        _totalSupply,
        lastAccruedTimestamp()
      );
  }

  function _calcFeeFraction(uint256 annualFee, uint256 duration) private pure returns (uint256) {
    return annualFee.mulDiv(duration, 365 days);
  }

  /*//////////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

  /// @notice Mints the next accrued management fee shares.
  /// This function can be called by anyone.
  function accrueManagementFeeShares() public {
    _accrueManagementFeeShares(feeRecipient());
  }

  /*//////////////////////////////////////////////////////////////
                         PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

  /// @notice Returns the accrued shares of the management fee recipient
  function nextManagementFeeShares() public view returns (uint256) {
    return
      _nextManagementFeeShares(
        feeRecipient(),
        managementFee(),
        totalSupply(),
        lastAccruedTimestamp()
      );
  }

  /*//////////////////////////////////////////////////////////////
                            STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

  /// @notice The address of a fee recipient who receives the management and performance fees.
  function feeRecipient() public view returns (address) {
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

  /// @notice The last accrued block.timestamp when the management was accrued.
  function lastAccruedTimestamp() public view returns (uint256) {
    return GenesisVaultManagedVaultStorage.layout().lastAccruedTimestamp;
  }

  /// @notice The high water mark of total assets where the performance fee was collected.
  function highWaterMark() public view returns (uint256) {
    return GenesisVaultManagedVaultStorage.layout().hwm;
  }

  /// @notice The last block.timestamp when the performance fee was harvested.
  function lastHarvestedTimestamp() public view returns (uint256) {
    return GenesisVaultManagedVaultStorage.layout().lastHarvestedTimestamp;
  }

  /// @notice The address of a white list provider who provides users allowed to use the vault.
  /// Supposed to be used in private mode, and will be disabled in public mode by setting to zero address.
  function whitelistProvider() public view returns (address) {
    return GenesisVaultManagedVaultStorage.layout().whitelistProvider;
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
    $.admin = account;
    emit AdminUpdated(_msgSender(), account);
  }
}
