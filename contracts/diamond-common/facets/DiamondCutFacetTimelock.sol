// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IDiamondCut } from "../interfaces/IDiamondCut.sol";
import { LibDiamond } from "../libraries/LibDiamond.sol";
import { ITimelockController } from "../../governance/interfaces/ITimelockController.sol";

/**
 * @title DiamondCutFacetTimelock
 * @notice Diamond cut facet with timelock protection
 * @dev Replaces DiamondCutFacet to add 48-hour timelock delay for upgrades
 * @dev Does not implement diamondCut() directly - use proposeDiamondCut() instead
 */
contract DiamondCutFacetTimelock {
  // ============ Events ============

  event DiamondCutProposed(bytes32 indexed proposalId, uint256 executeTime, address proposer);
  event DiamondCutExecuted(bytes32 indexed proposalId, address executor);
  event DiamondCutCancelled(bytes32 indexed proposalId, address canceller);

  // ============ Errors ============

  error TimelockNotSet();
  error TimelockNotEnabled();
  error OnlyOwner();
  error OnlyTimelock();

  // ============ Modifiers ============

  modifier onlyOwner() {
    if (msg.sender != LibDiamond.contractOwner()) revert OnlyOwner();
    _;
  }

  modifier onlyTimelock() {
    if (msg.sender != LibDiamond.getCriticalTimelock()) revert OnlyTimelock();
    _;
  }

  // ============ Proposal Functions ============

  /**
   * @notice Propose a diamond cut (schedule in timelock)
   * @dev Requires 48-hour delay before execution
   * @param _diamondCut Contains the facet addresses and function selectors
   * @param _init The address of the contract or facet to execute _calldata
   * @param _calldata A function call, including function selector and arguments
   */
  function proposeDiamondCut(
    IDiamondCut.FacetCut[] calldata _diamondCut,
    address _init,
    bytes calldata _calldata
  ) external onlyOwner {
    address timelock = LibDiamond.getCriticalTimelock();
    if (timelock == address(0)) revert TimelockNotSet();
    if (!LibDiamond.isTimelockEnabled()) revert TimelockNotEnabled();

    // Encode the execution call
    bytes memory data = abi.encodeWithSelector(
      this.executeDiamondCut.selector,
      _diamondCut,
      _init,
      _calldata
    );

    // Calculate proposal ID
    bytes32 salt = keccak256(abi.encodePacked(block.timestamp, msg.sender));
    bytes32 proposalId = ITimelockController(timelock).hashOperation(
      address(this),
      0,
      data,
      bytes32(0),
      salt
    );

    // Get timelock delay (48 hours)
    uint256 delay = ITimelockController(timelock).getMinDelay();
    uint256 executeTime = block.timestamp + delay;

    // Schedule in TimelockController
    ITimelockController(timelock).schedule(address(this), 0, data, bytes32(0), salt, delay);

    emit DiamondCutProposed(proposalId, executeTime, msg.sender);
  }

  /**
   * @notice Execute a diamond cut (called by timelock after delay)
   * @dev Can only be called by the timelock contract
   * @param _diamondCut Contains the facet addresses and function selectors
   * @param _init The address of the contract or facet to execute _calldata
   * @param _calldata A function call, including function selector and arguments
   */
  function executeDiamondCut(
    IDiamondCut.FacetCut[] calldata _diamondCut,
    address _init,
    bytes calldata _calldata
  ) external onlyTimelock {
    LibDiamond.diamondCut(_diamondCut, _init, _calldata);

    // Calculate proposal ID for event
    bytes memory data = abi.encodeWithSelector(
      this.executeDiamondCut.selector,
      _diamondCut,
      _init,
      _calldata
    );
    bytes32 proposalId = keccak256(data);

    emit DiamondCutExecuted(proposalId, msg.sender);
  }

  /**
   * @notice Cancel a pending diamond cut proposal
   * @dev Can only be called by owner
   * @param proposalId The ID of the proposal to cancel
   */
  function cancelDiamondCut(bytes32 proposalId) external onlyOwner {
    address timelock = LibDiamond.getCriticalTimelock();
    if (timelock == address(0)) revert TimelockNotSet();

    ITimelockController(timelock).cancel(proposalId);

    emit DiamondCutCancelled(proposalId, msg.sender);
  }

  // ============ View Functions ============

  /**
   * @notice Check if a proposal is pending
   * @param proposalId The ID of the proposal
   */
  function isProposalPending(bytes32 proposalId) external view returns (bool) {
    address timelock = LibDiamond.getCriticalTimelock();
    if (timelock == address(0)) return false;
    return ITimelockController(timelock).isOperationPending(proposalId);
  }

  /**
   * @notice Check if a proposal is ready to execute
   * @param proposalId The ID of the proposal
   */
  function isProposalReady(bytes32 proposalId) external view returns (bool) {
    address timelock = LibDiamond.getCriticalTimelock();
    if (timelock == address(0)) return false;
    return ITimelockController(timelock).isOperationReady(proposalId);
  }

  /**
   * @notice Get the timestamp when a proposal becomes ready
   * @param proposalId The ID of the proposal
   */
  function getProposalTimestamp(bytes32 proposalId) external view returns (uint256) {
    address timelock = LibDiamond.getCriticalTimelock();
    if (timelock == address(0)) return 0;
    return ITimelockController(timelock).getTimestamp(proposalId);
  }

  /**
   * @notice Get the timelock delay
   */
  function getTimelockDelay() external view returns (uint256) {
    address timelock = LibDiamond.getCriticalTimelock();
    if (timelock == address(0)) return 0;
    return ITimelockController(timelock).getMinDelay();
  }

  // ============ Admin Functions ============

  /**
   * @notice Set the critical timelock address
   * @dev Can only be called by owner
   * @param _timelock The timelock address
   */
  function setCriticalTimelock(address _timelock) external onlyOwner {
    LibDiamond.setCriticalTimelock(_timelock);
  }

  /**
   * @notice Enable or disable timelock
   * @dev Can only be called by owner
   * @param _enabled Whether to enable timelock
   */
  function setTimelockEnabled(bool _enabled) external onlyOwner {
    LibDiamond.setTimelockEnabled(_enabled);
  }

  /**
   * @notice Get the critical timelock address
   */
  function getCriticalTimelock() external view returns (address) {
    return LibDiamond.getCriticalTimelock();
  }

  /**
   * @notice Check if timelock is enabled
   */
  function isTimelockEnabled() external view returns (bool) {
    return LibDiamond.isTimelockEnabled();
  }
}
