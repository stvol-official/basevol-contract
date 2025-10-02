// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibGenesisVaultStorage } from "../libraries/LibGenesisVaultStorage.sol";
import { LibDiamond } from "../../diamond-common/libraries/LibDiamond.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC7540 } from "../../core/vault/interfaces/IERC7540.sol";

/**
 * @title GenesisVaultInitializationFacet
 * @notice Initialization logic for GenesisVault Diamond
 * @dev Can only be called once during deployment
 */
contract GenesisVaultInitializationFacet {
  // ============ Events ============
  event GenesisVaultInitialized(
    address indexed asset,
    string name,
    string symbol,
    address indexed strategy,
    address indexed baseVolContract
  );

  // ============ Initialization ============

  /**
   * @notice Initialize the GenesisVault Diamond
   * @param _asset The underlying asset (e.g., USDC)
   * @param _name Vault name
   * @param _symbol Vault symbol
   * @param _admin Admin address (can pause/unpause)
   * @param _baseVolContract BaseVol contract address
   * @param _strategy GenesisStrategy contract address
   * @param _feeRecipient Fee recipient address
   * @param _managementFee Annual management fee (e.g., 200 = 2%)
   * @param _performanceFee Performance fee (e.g., 2000 = 20%)
   * @param _hurdleRate Hurdle rate (e.g., 500 = 5%)
   * @param _entryCost Entry cost in basis points
   * @param _exitCost Exit cost in basis points
   * @param _userDepositLimit User deposit limit
   * @param _vaultDepositLimit Vault deposit limit
   */
  function initialize(
    address _asset,
    string memory _name,
    string memory _symbol,
    address _admin,
    address _baseVolContract,
    address _strategy,
    address _feeRecipient,
    uint256 _managementFee,
    uint256 _performanceFee,
    uint256 _hurdleRate,
    uint256 _entryCost,
    uint256 _exitCost,
    uint256 _userDepositLimit,
    uint256 _vaultDepositLimit
  ) external {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    // Ensure this can only be called once
    require(address(s.asset) == address(0), "GenesisVaultInitializationFacet: Already initialized");
    require(_asset != address(0), "GenesisVaultInitializationFacet: Invalid asset");
    require(_admin != address(0), "GenesisVaultInitializationFacet: Invalid admin");
    require(_feeRecipient != address(0), "GenesisVaultInitializationFacet: Invalid fee recipient");

    // Core vault configuration
    s.asset = IERC20(_asset);
    s.name = _name;
    s.symbol = _symbol;

    // Cache decimals from asset
    try IERC20Metadata(_asset).decimals() returns (uint8 assetDecimals) {
      s.decimals = assetDecimals;
    } catch {
      // Fallback to 18 if asset doesn't support decimals()
      s.decimals = 18;
    }

    s.admin = _admin;
    s.owner = LibDiamond.contractOwner(); // Set from Diamond owner

    // Integration addresses
    s.baseVolContract = _baseVolContract;
    s.strategy = _strategy;

    // Fee configuration
    s.feeRecipient = _feeRecipient;
    s.managementFee = _managementFee;
    s.performanceFee = _performanceFee;
    s.hurdleRate = _hurdleRate;
    s.entryCost = _entryCost;
    s.exitCost = _exitCost;

    // Limits
    s.userDepositLimit = _userDepositLimit;
    s.vaultDepositLimit = _vaultDepositLimit;

    // Initial state
    s.paused = false;
    s.shutdown = false;

    // Initialize management fee data
    s.managementFeeData.lastFeeTimestamp = block.timestamp;
    s.managementFeeData.totalFeesCollected = 0;

    // Approve strategy to spend assets (if strategy is set)
    if (_strategy != address(0)) {
      s.asset.approve(_strategy, type(uint256).max);
    }

    // Register supported interfaces for ERC165
    LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
    ds.supportedInterfaces[type(IERC165).interfaceId] = true;
    ds.supportedInterfaces[type(IERC20).interfaceId] = true;
    ds.supportedInterfaces[type(IERC4626).interfaceId] = true;
    ds.supportedInterfaces[type(IERC7540).interfaceId] = true;

    emit GenesisVaultInitialized(_asset, _name, _symbol, _strategy, _baseVolContract);
  }

  /**
   * @notice Add initial keepers
   * @param _keepers Array of keeper addresses
   */
  function addInitialKeepers(address[] memory _keepers) external {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    require(
      LibDiamond.contractOwner() == msg.sender,
      "GenesisVaultInitializationFacet: Only owner"
    );

    for (uint256 i = 0; i < _keepers.length; i++) {
      require(_keepers[i] != address(0), "GenesisVaultInitializationFacet: Invalid keeper");

      // Check for duplicates
      bool exists = false;
      for (uint256 j = 0; j < s.keepers.length; j++) {
        if (s.keepers[j] == _keepers[i]) {
          exists = true;
          break;
        }
      }

      if (!exists) {
        s.keepers.push(_keepers[i]);
      }
    }
  }
}
