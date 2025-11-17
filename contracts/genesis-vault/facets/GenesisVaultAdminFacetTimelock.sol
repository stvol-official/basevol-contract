// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibGenesisVaultStorage } from "../libraries/LibGenesisVaultStorage.sol";
import { LibDiamond } from "../../diamond-common/libraries/LibDiamond.sol";
import { IGenesisStrategy } from "../../core/vault/interfaces/IGenesisStrategy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ITimelockController } from "../../governance/interfaces/ITimelockController.sol";

/**
 * @title GenesisVaultAdminFacetTimelock
 * @notice Admin functions with timelock protection for GenesisVault
 * @dev Critical operations require 48-hour timelock delay, less critical require 12-hour delay
 */
contract GenesisVaultAdminFacetTimelock {
  using SafeERC20 for IERC20;

  // ============ Constants ============

  uint256 internal constant FLOAT_PRECISION = 1e18;
  uint256 private constant MAX_MANAGEMENT_FEE = 5e16; // 5%
  uint256 private constant MAX_PERFORMANCE_FEE = 5e17; // 50%
  uint256 private constant MAX_FIXED_COST = 1000e6; // 1000 USDC (assuming 6 decimals)
  uint256 private constant MAX_STRATEGY_APPROVAL = 1_000_000e6; // 1M USDC

  // ============ Errors ============

  error TimelockNotSet();
  error TimelockNotEnabled();
  error OnlyTimelock();
  error OnlyOwner();
  error OnlyAdmin();
  error InvalidAddress();
  error InvalidFeeValue();
  error InvalidStrategy();

  // ============ Events ============

  // Critical Timelock Events (48h)
  event StrategyChangeProposed(
    bytes32 indexed proposalId,
    address indexed newStrategy,
    uint256 executeTime
  );
  event StrategyChanged(address indexed oldStrategy, address indexed newStrategy);
  event StrategyApprovalGranted(address indexed strategy, uint256 amount);
  event StrategyApprovalRevoked(address indexed strategy);

  event FeeInfosChangeProposed(
    bytes32 indexed proposalId,
    address feeRecipient,
    uint256 managementFee,
    uint256 performanceFee,
    uint256 hurdleRate,
    uint256 executeTime
  );
  event FeeInfosChanged(
    address feeRecipient,
    uint256 managementFee,
    uint256 performanceFee,
    uint256 hurdleRate
  );

  event AdminChangeProposed(
    bytes32 indexed proposalId,
    address indexed newAdmin,
    uint256 executeTime
  );
  event AdminSet(address indexed oldAdmin, address indexed newAdmin);

  event BaseVolContractChangeProposed(
    bytes32 indexed proposalId,
    address indexed newBaseVolContract,
    uint256 executeTime
  );
  event BaseVolContractSet(address indexed baseVolContract);

  event ClearingHouseChangeProposed(
    bytes32 indexed proposalId,
    address indexed newClearingHouse,
    uint256 executeTime
  );
  event ClearingHouseSet(address indexed clearingHouse);

  // Less Critical Timelock Events (12h)
  event DepositLimitsChangeProposed(
    bytes32 indexed proposalId,
    uint256 userLimit,
    uint256 vaultLimit,
    uint256 executeTime
  );
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

  event EntryExitCostChangeProposed(
    bytes32 indexed proposalId,
    uint256 entryCost,
    uint256 exitCost,
    uint256 executeTime
  );
  event EntryCostUpdated(address account, uint256 newEntryCost);
  event ExitCostUpdated(address account, uint256 newExitCost);

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

  modifier onlyTimelock() {
    LibDiamond.enforceIsTimelock();
    _;
  }

  // ============ Critical Timelock Functions (48h) ============

  /**
   * @notice Propose to set strategy contract
   * @param _strategy New strategy address
   */
  function proposeSetStrategy(address _strategy) external onlyOwner {
    if (_strategy == address(0)) revert InvalidAddress();

    address timelock = LibDiamond.getCriticalTimelock();
    if (timelock == address(0)) revert TimelockNotSet();
    if (!LibDiamond.isTimelockEnabled()) revert TimelockNotEnabled();

    // Validate strategy before proposing
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    if (
      IGenesisStrategy(_strategy).asset() != address(s.asset) ||
      IGenesisStrategy(_strategy).vault() != address(this)
    ) {
      revert InvalidStrategy();
    }

    bytes memory data = abi.encodeWithSelector(this.executeSetStrategy.selector, _strategy);

    bytes32 salt = keccak256(abi.encodePacked("setStrategy", block.timestamp, _strategy));
    bytes32 proposalId = ITimelockController(timelock).hashOperation(
      address(this),
      0,
      data,
      bytes32(0),
      salt
    );

    uint256 delay = ITimelockController(timelock).getMinDelay();
    uint256 executeTime = block.timestamp + delay;

    ITimelockController(timelock).schedule(address(this), 0, data, bytes32(0), salt, delay);

    emit StrategyChangeProposed(proposalId, _strategy, executeTime);
  }

  /**
   * @notice Execute strategy change (called by timelock)
   * @param _strategy New strategy address
   */
  function executeSetStrategy(address _strategy) external onlyTimelock {
    if (_strategy == address(0)) revert InvalidAddress();

    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    address prevStrategy = s.strategy;

    // Stop and revoke approval from old strategy
    if (prevStrategy != address(0)) {
      IGenesisStrategy(prevStrategy).stop();
      s.asset.approve(prevStrategy, 0);
      emit StrategyApprovalRevoked(prevStrategy);
    }

    // Validate new strategy
    if (
      IGenesisStrategy(_strategy).asset() != address(s.asset) ||
      IGenesisStrategy(_strategy).vault() != address(this)
    ) {
      revert InvalidStrategy();
    }

    s.strategy = _strategy;

    // Grant capped approval
    s.asset.approve(_strategy, MAX_STRATEGY_APPROVAL);
    emit StrategyApprovalGranted(_strategy, MAX_STRATEGY_APPROVAL);

    emit StrategyChanged(prevStrategy, _strategy);
  }

  /**
   * @notice Propose to set fee information
   * @param _feeRecipient The address to receive all fees
   * @param _managementFee The management fee percent (18 decimals)
   * @param _performanceFee The performance fee percent (18 decimals)
   * @param _hurdleRate The hurdle rate percent (18 decimals)
   */
  function proposeSetFeeInfos(
    address _feeRecipient,
    uint256 _managementFee,
    uint256 _performanceFee,
    uint256 _hurdleRate
  ) external onlyAdmin {
    if (_managementFee > MAX_MANAGEMENT_FEE) revert InvalidFeeValue();
    if (_performanceFee > MAX_PERFORMANCE_FEE) revert InvalidFeeValue();
    if (_feeRecipient == address(0)) revert InvalidAddress();

    address timelock = LibDiamond.getCriticalTimelock();
    if (timelock == address(0)) revert TimelockNotSet();
    if (!LibDiamond.isTimelockEnabled()) revert TimelockNotEnabled();

    bytes memory data = abi.encodeWithSelector(
      this.executeSetFeeInfos.selector,
      _feeRecipient,
      _managementFee,
      _performanceFee,
      _hurdleRate
    );

    bytes32 salt = keccak256(
      abi.encodePacked(
        "setFeeInfos",
        block.timestamp,
        _feeRecipient,
        _managementFee,
        _performanceFee,
        _hurdleRate
      )
    );
    bytes32 proposalId = ITimelockController(timelock).hashOperation(
      address(this),
      0,
      data,
      bytes32(0),
      salt
    );

    uint256 delay = ITimelockController(timelock).getMinDelay();
    uint256 executeTime = block.timestamp + delay;

    ITimelockController(timelock).schedule(address(this), 0, data, bytes32(0), salt, delay);

    emit FeeInfosChangeProposed(
      proposalId,
      _feeRecipient,
      _managementFee,
      _performanceFee,
      _hurdleRate,
      executeTime
    );
  }

  /**
   * @notice Execute fee information change (called by timelock)
   */
  function executeSetFeeInfos(
    address _feeRecipient,
    uint256 _managementFee,
    uint256 _performanceFee,
    uint256 _hurdleRate
  ) external onlyTimelock {
    if (_managementFee > MAX_MANAGEMENT_FEE) revert InvalidFeeValue();
    if (_performanceFee > MAX_PERFORMANCE_FEE) revert InvalidFeeValue();
    if (_feeRecipient == address(0)) revert InvalidAddress();

    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    s.feeRecipient = _feeRecipient;
    s.managementFee = _managementFee;
    s.performanceFee = _performanceFee;
    s.hurdleRate = _hurdleRate;

    emit FeeInfosChanged(_feeRecipient, _managementFee, _performanceFee, _hurdleRate);
  }

  /**
   * @notice Propose to set admin address
   * @param _admin New admin address
   */
  function proposeSetAdmin(address _admin) external onlyOwner {
    if (_admin == address(0)) revert InvalidAddress();

    address timelock = LibDiamond.getCriticalTimelock();
    if (timelock == address(0)) revert TimelockNotSet();
    if (!LibDiamond.isTimelockEnabled()) revert TimelockNotEnabled();

    bytes memory data = abi.encodeWithSelector(this.executeSetAdmin.selector, _admin);

    bytes32 salt = keccak256(abi.encodePacked("setAdmin", block.timestamp, _admin));
    bytes32 proposalId = ITimelockController(timelock).hashOperation(
      address(this),
      0,
      data,
      bytes32(0),
      salt
    );

    uint256 delay = ITimelockController(timelock).getMinDelay();
    uint256 executeTime = block.timestamp + delay;

    ITimelockController(timelock).schedule(address(this), 0, data, bytes32(0), salt, delay);

    emit AdminChangeProposed(proposalId, _admin, executeTime);
  }

  /**
   * @notice Execute admin change (called by timelock)
   * @param _admin New admin address
   */
  function executeSetAdmin(address _admin) external onlyTimelock {
    if (_admin == address(0)) revert InvalidAddress();

    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    address oldAdmin = s.admin;
    s.admin = _admin;

    emit AdminSet(oldAdmin, _admin);
  }

  /**
   * @notice Propose to set BaseVol contract address
   * @param _baseVolContract BaseVol contract address
   */
  function proposeSetBaseVolContract(address _baseVolContract) external onlyOwner {
    if (_baseVolContract == address(0)) revert InvalidAddress();

    address timelock = LibDiamond.getCriticalTimelock();
    if (timelock == address(0)) revert TimelockNotSet();
    if (!LibDiamond.isTimelockEnabled()) revert TimelockNotEnabled();

    bytes memory data = abi.encodeWithSelector(
      this.executeSetBaseVolContract.selector,
      _baseVolContract
    );

    bytes32 salt = keccak256(
      abi.encodePacked("setBaseVolContract", block.timestamp, _baseVolContract)
    );
    bytes32 proposalId = ITimelockController(timelock).hashOperation(
      address(this),
      0,
      data,
      bytes32(0),
      salt
    );

    uint256 delay = ITimelockController(timelock).getMinDelay();
    uint256 executeTime = block.timestamp + delay;

    ITimelockController(timelock).schedule(address(this), 0, data, bytes32(0), salt, delay);

    emit BaseVolContractChangeProposed(proposalId, _baseVolContract, executeTime);
  }

  /**
   * @notice Execute BaseVol contract change (called by timelock)
   * @param _baseVolContract BaseVol contract address
   */
  function executeSetBaseVolContract(address _baseVolContract) external onlyTimelock {
    if (_baseVolContract == address(0)) revert InvalidAddress();

    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    s.baseVolContract = _baseVolContract;

    emit BaseVolContractSet(_baseVolContract);
  }

  /**
   * @notice Propose to set ClearingHouse contract address
   * @param _clearingHouse ClearingHouse contract address
   */
  function proposeSetClearingHouse(address _clearingHouse) external onlyOwner {
    if (_clearingHouse == address(0)) revert InvalidAddress();

    address timelock = LibDiamond.getCriticalTimelock();
    if (timelock == address(0)) revert TimelockNotSet();
    if (!LibDiamond.isTimelockEnabled()) revert TimelockNotEnabled();

    bytes memory data = abi.encodeWithSelector(
      this.executeSetClearingHouse.selector,
      _clearingHouse
    );

    bytes32 salt = keccak256(abi.encodePacked("setClearingHouse", block.timestamp, _clearingHouse));
    bytes32 proposalId = ITimelockController(timelock).hashOperation(
      address(this),
      0,
      data,
      bytes32(0),
      salt
    );

    uint256 delay = ITimelockController(timelock).getMinDelay();
    uint256 executeTime = block.timestamp + delay;

    ITimelockController(timelock).schedule(address(this), 0, data, bytes32(0), salt, delay);

    emit ClearingHouseChangeProposed(proposalId, _clearingHouse, executeTime);
  }

  /**
   * @notice Execute ClearingHouse change (called by timelock)
   * @param _clearingHouse ClearingHouse contract address
   */
  function executeSetClearingHouse(address _clearingHouse) external onlyTimelock {
    if (_clearingHouse == address(0)) revert InvalidAddress();

    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    s.clearingHouse = _clearingHouse;

    emit ClearingHouseSet(_clearingHouse);
  }

  // ============ Less Critical Timelock Functions (12h) ============

  /**
   * @notice Propose to set deposit limits
   * @param userLimit Maximum deposit per user
   * @param vaultLimit Maximum total deposits for vault
   */
  function proposeSetDepositLimits(uint256 userLimit, uint256 vaultLimit) external onlyAdmin {
    require(userLimit <= vaultLimit, "User limit cannot exceed vault limit");

    address timelock = LibDiamond.getStandardTimelock();
    if (timelock == address(0)) revert TimelockNotSet();
    if (!LibDiamond.isTimelockEnabled()) revert TimelockNotEnabled();

    bytes memory data = abi.encodeWithSelector(
      this.executeSetDepositLimits.selector,
      userLimit,
      vaultLimit
    );

    bytes32 salt = keccak256(
      abi.encodePacked("setDepositLimits", block.timestamp, userLimit, vaultLimit)
    );
    bytes32 proposalId = ITimelockController(timelock).hashOperation(
      address(this),
      0,
      data,
      bytes32(0),
      salt
    );

    uint256 delay = ITimelockController(timelock).getMinDelay();
    uint256 executeTime = block.timestamp + delay;

    ITimelockController(timelock).schedule(address(this), 0, data, bytes32(0), salt, delay);

    emit DepositLimitsChangeProposed(proposalId, userLimit, vaultLimit, executeTime);
  }

  /**
   * @notice Execute deposit limits change (called by timelock)
   */
  function executeSetDepositLimits(uint256 userLimit, uint256 vaultLimit) external onlyTimelock {
    require(userLimit <= vaultLimit, "User limit cannot exceed vault limit");

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

  /**
   * @notice Propose to set entry and exit costs
   * @param _entryCost Entry cost as a fixed amount in asset units
   * @param _exitCost Exit cost as a fixed amount in asset units
   */
  function proposeSetEntryAndExitCost(uint256 _entryCost, uint256 _exitCost) external onlyAdmin {
    if (_entryCost > MAX_FIXED_COST) revert InvalidFeeValue();
    if (_exitCost > MAX_FIXED_COST) revert InvalidFeeValue();

    address timelock = LibDiamond.getStandardTimelock();
    if (timelock == address(0)) revert TimelockNotSet();
    if (!LibDiamond.isTimelockEnabled()) revert TimelockNotEnabled();

    bytes memory data = abi.encodeWithSelector(
      this.executeSetEntryAndExitCost.selector,
      _entryCost,
      _exitCost
    );

    bytes32 salt = keccak256(
      abi.encodePacked("setEntryAndExitCost", block.timestamp, _entryCost, _exitCost)
    );
    bytes32 proposalId = ITimelockController(timelock).hashOperation(
      address(this),
      0,
      data,
      bytes32(0),
      salt
    );

    uint256 delay = ITimelockController(timelock).getMinDelay();
    uint256 executeTime = block.timestamp + delay;

    ITimelockController(timelock).schedule(address(this), 0, data, bytes32(0), salt, delay);

    emit EntryExitCostChangeProposed(proposalId, _entryCost, _exitCost, executeTime);
  }

  /**
   * @notice Execute entry and exit cost change (called by timelock)
   */
  function executeSetEntryAndExitCost(uint256 _entryCost, uint256 _exitCost) external onlyTimelock {
    if (_entryCost > MAX_FIXED_COST) revert InvalidFeeValue();
    if (_exitCost > MAX_FIXED_COST) revert InvalidFeeValue();

    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    if (s.entryCost != _entryCost) {
      s.entryCost = _entryCost;
      emit EntryCostUpdated(msg.sender, _entryCost);
    }

    if (s.exitCost != _exitCost) {
      s.exitCost = _exitCost;
      emit ExitCostUpdated(msg.sender, _exitCost);
    }
  }
}
