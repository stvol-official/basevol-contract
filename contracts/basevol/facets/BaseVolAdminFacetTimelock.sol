// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibBaseVolStrike } from "../libraries/LibBaseVolStrike.sol";
import { LibDiamond } from "../../diamond-common/libraries/LibDiamond.sol";
import { PriceInfo } from "../../types/Types.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPyth } from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { PythLazer } from "../../libraries/PythLazer.sol";
import { ITimelockController } from "../../governance/interfaces/ITimelockController.sol";

/**
 * @title BaseVolAdminFacetTimelock
 * @notice Admin facet with timelock protection for BaseVol
 * @dev Critical operations require 6-48 hour timelock delay
 */
contract BaseVolAdminFacetTimelock {
  using LibBaseVolStrike for LibBaseVolStrike.DiamondStorage;
  using SafeERC20 for IERC20;

  uint256 private constant MAX_COMMISSION_FEE = 5000; // 50%

  // ============ Events ============

  event PriceIdAdded(uint256 indexed productId, bytes32 priceId, string symbol);

  // Timelock proposal events
  event OracleChangeProposed(
    bytes32 indexed proposalId,
    address indexed newOracle,
    uint256 executeTime
  );
  event OracleChanged(address indexed oldOracle, address indexed newOracle);

  event CommissionFeeChangeProposed(
    bytes32 indexed proposalId,
    uint256 newFee,
    uint256 executeTime
  );
  event CommissionFeeScheduled(uint256 newFee, uint256 currentFee, uint256 timestamp);

  event PythLazerChangeProposed(
    bytes32 indexed proposalId,
    address indexed newPythLazer,
    uint256 executeTime
  );
  event PythLazerChanged(address indexed oldPythLazer, address indexed newPythLazer);

  event OperatorChangeProposed(
    bytes32 indexed proposalId,
    address indexed newOperator,
    uint256 executeTime
  );
  event OperatorChanged(address indexed oldOperator, address indexed newOperator);

  event AdminChangeProposed(
    bytes32 indexed proposalId,
    address indexed newAdmin,
    uint256 executeTime
  );
  event AdminChanged(address indexed oldAdmin, address indexed newAdmin);

  event TokenChangeProposed(
    bytes32 indexed proposalId,
    address indexed newToken,
    uint256 executeTime
  );
  event TokenChanged(address indexed oldToken, address indexed newToken);

  event ProposalCancelled(bytes32 indexed proposalId, string reason);

  // ============ Errors ============

  error TimelockNotSet();
  error TimelockNotEnabled();
  error OnlyOwner();
  error OnlyAdmin();
  error OnlyOperator();
  error OnlyTimelock();

  // ============ Modifiers ============

  modifier onlyOwner() {
    LibDiamond.enforceIsContractOwner();
    _;
  }

  modifier onlyAdmin() {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    if (msg.sender != bvs.adminAddress) revert OnlyAdmin();
    _;
  }

  modifier onlyOperator() {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    if (msg.sender != bvs.operatorAddress) revert OnlyOperator();
    _;
  }

  modifier onlyTimelock() {
    LibDiamond.enforceIsCriticalTimelock();
    _;
  }

  // ============ Owner Functions (No Timelock) ============

  function transferOwnership(address _newOwner) external onlyOwner {
    if (_newOwner == address(0)) revert LibBaseVolStrike.InvalidAddress();
    LibDiamond.setContractOwner(_newOwner);
  }

  function owner() external view returns (address) {
    return LibDiamond.contractOwner();
  }

  // ============ Critical Admin Functions (With Timelock) ============

  /**
   * @notice Propose to set a new oracle address
   * @param _oracle New oracle address
   */
  function proposeSetOracle(address _oracle) external onlyAdmin {
    if (_oracle == address(0)) revert LibBaseVolStrike.InvalidAddress();

    address timelock = LibDiamond.getCriticalTimelock();
    if (timelock == address(0)) revert TimelockNotSet();
    if (!LibDiamond.isTimelockEnabled()) revert TimelockNotEnabled();

    bytes memory data = abi.encodeWithSelector(this.executeSetOracle.selector, _oracle);

    bytes32 salt = keccak256(abi.encodePacked("setOracle", block.timestamp, _oracle));
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

    emit OracleChangeProposed(proposalId, _oracle, executeTime);
  }

  /**
   * @notice Execute oracle change (called by timelock)
   * @param _oracle New oracle address
   */
  function executeSetOracle(address _oracle) external onlyTimelock {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    address oldOracle = address(bvs.oracle);
    bvs.oracle = IPyth(_oracle);
    emit OracleChanged(oldOracle, _oracle);
  }

  /**
   * @notice Propose to set commission fee
   * @param _commissionfee New commission fee
   */
  function proposeSetCommissionfee(uint256 _commissionfee) external onlyAdmin {
    if (_commissionfee > MAX_COMMISSION_FEE) revert LibBaseVolStrike.InvalidCommissionFee();

    address timelock = LibDiamond.getCriticalTimelock();
    if (timelock == address(0)) revert TimelockNotSet();
    if (!LibDiamond.isTimelockEnabled()) revert TimelockNotEnabled();

    bytes memory data = abi.encodeWithSelector(
      this.executeSetCommissionfee.selector,
      _commissionfee
    );

    bytes32 salt = keccak256(abi.encodePacked("setCommissionfee", block.timestamp, _commissionfee));
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

    emit CommissionFeeChangeProposed(proposalId, _commissionfee, executeTime);
  }

  /**
   * @notice Execute commission fee change (called by timelock)
   * @param _commissionfee New commission fee
   */
  function executeSetCommissionfee(uint256 _commissionfee) external onlyTimelock {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();

    // Store as pending commission fee to be applied to next round
    bvs.pendingCommissionFee = _commissionfee;

    emit CommissionFeeScheduled(_commissionfee, bvs.commissionfee, block.timestamp);
  }

  /**
   * @notice Propose to set Pyth Lazer address
   * @param _pythLazer New Pyth Lazer address
   */
  function proposeSetPythLazer(address _pythLazer) external onlyAdmin {
    if (_pythLazer == address(0)) revert LibBaseVolStrike.InvalidAddress();

    address timelock = LibDiamond.getCriticalTimelock();
    if (timelock == address(0)) revert TimelockNotSet();
    if (!LibDiamond.isTimelockEnabled()) revert TimelockNotEnabled();

    bytes memory data = abi.encodeWithSelector(this.executeSetPythLazer.selector, _pythLazer);

    bytes32 salt = keccak256(abi.encodePacked("setPythLazer", block.timestamp, _pythLazer));
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

    emit PythLazerChangeProposed(proposalId, _pythLazer, executeTime);
  }

  /**
   * @notice Execute Pyth Lazer change (called by timelock)
   * @param _pythLazer New Pyth Lazer address
   */
  function executeSetPythLazer(address _pythLazer) external onlyTimelock {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    address oldPythLazer = address(bvs.pythLazer);
    bvs.pythLazer = PythLazer(_pythLazer);
    emit PythLazerChanged(oldPythLazer, _pythLazer);
  }

  /**
   * @notice Propose to set operator address
   * @param _operatorAddress New operator address
   */
  function proposeSetOperator(address _operatorAddress) external onlyAdmin {
    if (_operatorAddress == address(0)) revert LibBaseVolStrike.InvalidAddress();

    address timelock = LibDiamond.getCriticalTimelock();
    if (timelock == address(0)) revert TimelockNotSet();
    if (!LibDiamond.isTimelockEnabled()) revert TimelockNotEnabled();

    bytes memory data = abi.encodeWithSelector(this.executeSetOperator.selector, _operatorAddress);

    bytes32 salt = keccak256(abi.encodePacked("setOperator", block.timestamp, _operatorAddress));
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

    emit OperatorChangeProposed(proposalId, _operatorAddress, executeTime);
  }

  /**
   * @notice Execute operator change (called by timelock)
   * @param _operatorAddress New operator address
   */
  function executeSetOperator(address _operatorAddress) external onlyTimelock {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    address oldOperator = bvs.operatorAddress;
    bvs.operatorAddress = _operatorAddress;
    emit OperatorChanged(oldOperator, _operatorAddress);
  }

  /**
   * @notice Propose to set admin address
   * @param _adminAddress New admin address
   */
  function proposeSetAdmin(address _adminAddress) external onlyOwner {
    if (_adminAddress == address(0)) revert LibBaseVolStrike.InvalidAddress();

    address timelock = LibDiamond.getCriticalTimelock();
    if (timelock == address(0)) revert TimelockNotSet();
    if (!LibDiamond.isTimelockEnabled()) revert TimelockNotEnabled();

    bytes memory data = abi.encodeWithSelector(this.executeSetAdmin.selector, _adminAddress);

    bytes32 salt = keccak256(abi.encodePacked("setAdmin", block.timestamp, _adminAddress));
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

    emit AdminChangeProposed(proposalId, _adminAddress, executeTime);
  }

  /**
   * @notice Execute admin change (called by timelock)
   * @param _adminAddress New admin address
   */
  function executeSetAdmin(address _adminAddress) external onlyTimelock {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    address oldAdmin = bvs.adminAddress;
    bvs.adminAddress = _adminAddress;
    emit AdminChanged(oldAdmin, _adminAddress);
  }

  /**
   * @notice Propose to set token address
   * @param _token New token address
   */
  function proposeSetToken(address _token) external onlyAdmin {
    if (_token == address(0)) revert LibBaseVolStrike.InvalidAddress();

    address timelock = LibDiamond.getCriticalTimelock();
    if (timelock == address(0)) revert TimelockNotSet();
    if (!LibDiamond.isTimelockEnabled()) revert TimelockNotEnabled();

    bytes memory data = abi.encodeWithSelector(this.executeSetToken.selector, _token);

    bytes32 salt = keccak256(abi.encodePacked("setToken", block.timestamp, _token));
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

    emit TokenChangeProposed(proposalId, _token, executeTime);
  }

  /**
   * @notice Execute token change (called by timelock)
   * @param _token New token address
   */
  function executeSetToken(address _token) external onlyTimelock {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    address oldToken = address(bvs.token);
    bvs.token = IERC20(_token);
    emit TokenChanged(oldToken, _token);
  }

  /**
   * @notice Cancel a pending proposal
   * @param proposalId The ID of the proposal to cancel
   * @param reason Reason for cancellation
   */
  function cancelProposal(bytes32 proposalId, string calldata reason) external onlyAdmin {
    address timelock = LibDiamond.getCriticalTimelock();
    if (timelock == address(0)) revert TimelockNotSet();

    ITimelockController(timelock).cancel(proposalId);

    emit ProposalCancelled(proposalId, reason);
  }

  // ============ Emergency Functions (No Timelock) ============

  function retrieveMisplacedETH() external onlyAdmin {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    payable(bvs.adminAddress).transfer(address(this).balance);
  }

  function retrieveMisplacedTokens(address _token) external onlyAdmin {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    if (address(bvs.token) == _token) revert LibBaseVolStrike.InvalidTokenAddress();
    IERC20 token = IERC20(_token);
    token.safeTransfer(bvs.adminAddress, token.balanceOf(address(this)));
  }

  // ============ Operator Functions (No Timelock) ============

  function setLastFilledOrderId(uint256 _lastFilledOrderId) external onlyOperator {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    bvs.lastFilledOrderId = _lastFilledOrderId;
  }

  function addPriceId(
    bytes32 _priceId,
    uint256 _productId,
    string calldata _symbol
  ) external onlyOperator {
    _addPriceId(_priceId, _productId, _symbol);
  }

  function setPriceInfo(PriceInfo calldata priceInfo) external onlyOperator {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();

    if (priceInfo.priceId == bytes32(0)) revert LibBaseVolStrike.InvalidPriceId();
    if (bytes(priceInfo.symbol).length == 0) revert LibBaseVolStrike.InvalidSymbol();

    uint256 existingProductId = bvs.priceIdToProductId[priceInfo.priceId];
    bytes32 oldPriceId = bvs.priceInfos[priceInfo.productId].priceId;

    if (existingProductId != priceInfo.productId) {
      if (existingProductId != 0 || bvs.priceInfos[0].priceId == priceInfo.priceId) {
        revert LibBaseVolStrike.PriceIdAlreadyExists();
      }
    }

    if (oldPriceId != bytes32(0)) {
      delete bvs.priceIdToProductId[oldPriceId];
    }

    bvs.priceInfos[priceInfo.productId] = priceInfo;
    bvs.priceIdToProductId[priceInfo.priceId] = priceInfo.productId;

    emit PriceIdAdded(priceInfo.productId, priceInfo.priceId, priceInfo.symbol);
  }

  // ============ Internal Functions ============

  function _addPriceId(bytes32 _priceId, uint256 _productId, string memory _symbol) internal {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    if (_priceId == bytes32(0)) revert LibBaseVolStrike.InvalidPriceId();
    if (bvs.priceIdToProductId[_priceId] != 0 || bvs.priceInfos[0].priceId == _priceId) {
      revert LibBaseVolStrike.PriceIdAlreadyExists();
    }
    if (bvs.priceInfos[_productId].priceId != bytes32(0)) {
      revert LibBaseVolStrike.ProductIdAlreadyExists();
    }
    if (bytes(_symbol).length == 0) {
      revert LibBaseVolStrike.InvalidSymbol();
    }

    bvs.priceInfos[_productId] = PriceInfo({
      priceId: _priceId,
      productId: _productId,
      symbol: _symbol
    });

    bvs.priceIdToProductId[_priceId] = _productId;
    bvs.priceIdCount++;

    emit PriceIdAdded(_productId, _priceId, _symbol);
  }

  // ============ View Functions ============

  function getCriticalTimelock() external view returns (address) {
    return LibDiamond.getCriticalTimelock();
  }

  function isTimelockEnabled() external view returns (bool) {
    return LibDiamond.isTimelockEnabled();
  }

  function getTimelockDelay() external view returns (uint256) {
    address timelock = LibDiamond.getCriticalTimelock();
    if (timelock == address(0)) return 0;
    return ITimelockController(timelock).getMinDelay();
  }
}
