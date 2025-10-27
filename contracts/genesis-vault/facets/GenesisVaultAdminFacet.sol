// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibGenesisVaultStorage } from "../libraries/LibGenesisVaultStorage.sol";
import { LibDiamond } from "../../diamond-common/libraries/LibDiamond.sol";
import { IGenesisStrategy } from "../../core/vault/interfaces/IGenesisStrategy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title GenesisVaultAdminFacet
 * @notice Admin functions for GenesisVault Diamond (including fee configuration)
 * @dev Only accessible by owner or admin
 */
contract GenesisVaultAdminFacet {
  using SafeERC20 for IERC20;

  // ============ Constants ============

  uint256 internal constant FLOAT_PRECISION = 1e18;
  uint256 private constant MAX_MANAGEMENT_FEE = 5e16; // 5%
  uint256 private constant MAX_PERFORMANCE_FEE = 5e17; // 50%
  uint256 private constant MAX_FIXED_COST = 1000e6; // 1000 USDC (assuming 6 decimals)

  // ============ Events ============

  // Core Admin Events
  event BaseVolContractSet(address indexed baseVolContract);
  event StrategyUpdated(address indexed oldStrategy, address indexed newStrategy);
  event Shutdown(address indexed account);
  event Paused(address indexed account);
  event Unpaused(address indexed account);
  event AdminSet(address indexed oldAdmin, address indexed newAdmin);

  // Fee Configuration Events
  event ManagementFeeChanged(address account, uint256 newManagementFee);
  event PerformanceFeeChanged(address account, uint256 newPerformanceFee);
  event HurdleRateChanged(address account, uint256 newHurdleRate);
  event EntryCostUpdated(address account, uint256 newEntryCost);
  event ExitCostUpdated(address account, uint256 newExitCost);
  event UserDepositLimitChanged(
    address account,
    uint256 oldUserDepositLimit,
    uint256 newUserDepositLimit
  );
  event VaultDepositLimitChanged(
    address account,
    uint256 oldVaultDepositLimit,
    uint256 newVaultDepositLimit
  );
  event FeeRecipientUpdated(
    address indexed account,
    address indexed oldRecipient,
    address indexed newRecipient
  );

  // ============ Errors ============

  error OnlyOwner();
  error OnlyAdmin();
  error InvalidStrategy();
  error InvalidAddress();
  error InvalidFeeValue();
  error VaultShutdown();
  error VaultNotPaused();
  error VaultPaused();
  error TotalSupplyNotZero();

  // ============ Modifiers ============

  modifier onlyOwner() {
    if (msg.sender != LibDiamond.contractOwner()) revert OnlyOwner();
    _;
  }

  modifier onlyAdmin() {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    if (msg.sender != s.admin) revert OnlyAdmin();
    _;
  }

  modifier whenNotPaused() {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    if (s.paused) revert VaultPaused();
    _;
  }

  modifier whenPaused() {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    if (!s.paused) revert VaultNotPaused();
    _;
  }

  // ============ Core Admin Functions ============

  /**
   * @notice Set BaseVol contract address
   * @param _baseVolContract BaseVol contract address
   */
  function setBaseVolContract(address _baseVolContract) external onlyOwner {
    if (_baseVolContract == address(0)) revert InvalidAddress();
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    s.baseVolContract = _baseVolContract;
    emit BaseVolContractSet(_baseVolContract);
  }

  /**
   * @notice Set strategy contract
   * @dev Approves new strategy and revokes old strategy approval
   * @param _strategy New strategy address
   */
  function setStrategy(address _strategy) external onlyOwner {
    if (_strategy == address(0)) revert InvalidAddress();

    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    address prevStrategy = s.strategy;

    // Stop and revoke approval from old strategy
    if (prevStrategy != address(0)) {
      IGenesisStrategy(prevStrategy).stop();
      s.asset.approve(prevStrategy, 0);
    }

    // Validate new strategy
    if (
      IGenesisStrategy(_strategy).asset() != address(s.asset) ||
      IGenesisStrategy(_strategy).vault() != address(this)
    ) {
      revert InvalidStrategy();
    }

    s.strategy = _strategy;
    s.asset.approve(_strategy, type(uint256).max);

    emit StrategyUpdated(prevStrategy, _strategy);
  }

  /**
   * @notice Transfer ownership of the contract
   * @param _newOwner New owner address
   */
  function transferOwnership(address _newOwner) external onlyOwner {
    if (_newOwner == address(0)) revert InvalidAddress();
    LibDiamond.setContractOwner(_newOwner);
  }

  /**
   * @notice Set admin address
   * @param _admin New admin address
   */
  function setAdmin(address _admin) external onlyOwner {
    if (_admin == address(0)) revert InvalidAddress();
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    address oldAdmin = s.admin;
    s.admin = _admin;
    emit AdminSet(oldAdmin, _admin);
  }

  /**
   * @notice Shutdown vault (disable deposits, keep withdrawals)
   */
  function shutdown() external onlyOwner {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    s.shutdown = true;

    if (s.strategy != address(0)) {
      IGenesisStrategy(s.strategy).stop();
    }

    emit Shutdown(msg.sender);
  }

  /**
   * @notice Pause vault (disable all operations)
   * @param stopStrategy Whether to stop strategy
   */
  function pause(bool stopStrategy) external onlyAdmin whenNotPaused {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    s.paused = true;

    if (s.strategy != address(0)) {
      if (stopStrategy) {
        IGenesisStrategy(s.strategy).stop();
      } else {
        IGenesisStrategy(s.strategy).pause();
      }
    }

    emit Paused(msg.sender);
  }

  /**
   * @notice Unpause vault
   */
  function unpause() external onlyAdmin whenPaused {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    s.paused = false;

    if (s.strategy != address(0)) {
      IGenesisStrategy(s.strategy).unpause();
    }

    emit Unpaused(msg.sender);
  }

  /**
   * @notice Sweep idle assets (only when vault is empty)
   * @param receiver Address to receive swept assets
   */
  function sweep(address receiver) external onlyOwner {
    if (receiver == address(0)) revert InvalidAddress();

    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    // Require all shares redeemed and no utilized assets
    if (s.totalSupply != 0) revert TotalSupplyNotZero();
    if (s.strategy != address(0)) {
      if (IGenesisStrategy(s.strategy).totalAssetsUnderManagement() != 0) {
        revert("Strategy has assets under management");
      }
    }

    // Sweep idle assets
    uint256 balance = s.asset.balanceOf(address(this));
    s.asset.safeTransfer(receiver, balance);
  }

  // ============ Fee Configuration Functions ============

  /// @dev Configures the fee information.
  ///
  /// @param _feeRecipient The address to receive all fees.
  /// @param _managementFee The management fee percent that is denominated in 18 decimals.
  /// @param _performanceFee The performance fee percent that is denominated in 18 decimals.
  /// @param _hurdleRate The hurdle rate percent that is denominated in 18 decimals.
  function setFeeInfos(
    address _feeRecipient,
    uint256 _managementFee,
    uint256 _performanceFee,
    uint256 _hurdleRate
  ) external onlyAdmin {
    if (_managementFee > MAX_MANAGEMENT_FEE) revert InvalidFeeValue();
    if (_performanceFee > MAX_PERFORMANCE_FEE) revert InvalidFeeValue();

    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    if (s.feeRecipient != _feeRecipient) {
      address oldFeeRecipient = s.feeRecipient;
      s.feeRecipient = _feeRecipient;
      emit FeeRecipientUpdated(msg.sender, oldFeeRecipient, _feeRecipient);
    }
    if (s.managementFee != _managementFee) {
      s.managementFee = _managementFee;
      emit ManagementFeeChanged(msg.sender, _managementFee);
    }
    if (s.performanceFee != _performanceFee) {
      s.performanceFee = _performanceFee;
      emit PerformanceFeeChanged(msg.sender, _performanceFee);
    }
    if (s.hurdleRate != _hurdleRate) {
      s.hurdleRate = _hurdleRate;
      emit HurdleRateChanged(msg.sender, _hurdleRate);
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

  /// @dev Sets the deposit limits including user and vault limit.
  function setDepositLimits(uint256 userLimit, uint256 vaultLimit) external onlyAdmin {
    _setDepositLimits(userLimit, vaultLimit);
  }

  // ============ Internal Helper Functions ============

  function _setEntryCost(uint256 value) internal {
    if (value > MAX_FIXED_COST) revert InvalidFeeValue();
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    if (s.entryCost != value) {
      s.entryCost = value;
      emit EntryCostUpdated(msg.sender, value);
    }
  }

  function _setExitCost(uint256 value) internal {
    if (value > MAX_FIXED_COST) revert InvalidFeeValue();
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    if (s.exitCost != value) {
      s.exitCost = value;
      emit ExitCostUpdated(msg.sender, value);
    }
  }

  function _setDepositLimits(uint256 userLimit, uint256 vaultLimit) internal {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    if (s.userDepositLimit != userLimit) {
      uint256 oldUserDepositLimit = s.userDepositLimit;
      s.userDepositLimit = userLimit;
      emit UserDepositLimitChanged(msg.sender, oldUserDepositLimit, userLimit);
    }
    if (s.vaultDepositLimit != vaultLimit) {
      uint256 oldVaultDepositLimit = s.vaultDepositLimit;
      s.vaultDepositLimit = vaultLimit;
      emit VaultDepositLimitChanged(msg.sender, oldVaultDepositLimit, vaultLimit);
    }
  }
}
