// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { GenesisVault } from "./GenesisVault.sol";
import { GenesisStrategy } from "./GenesisStrategy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IGenesisVault } from "./interfaces/IGenesisVault.sol";

contract GenesisVaultFactory is Initializable, Ownable2StepUpgradeable {
  struct VaultInfo {
    address vaultAddress;
    address strategyAddress;
    address asset;
    string name;
    string symbol;
    uint256 entryCost;
    uint256 exitCost;
    address owner;
    uint256 createdAt;
    bool isActive;
  }

  mapping(address => VaultInfo) public vaults;
  address[] public allVaults;

  event VaultCreated(
    address indexed vault,
    address indexed strategy,
    address indexed owner,
    string name,
    string symbol
  );

  event VaultDeactivated(address indexed vault, address indexed owner);

  constructor() {
    _disableInitializers();
  }

  function initialize(address owner_) external initializer {
    __Ownable_init(owner_);
  }

  function createVault(
    address asset_,
    uint256 entryCost_,
    uint256 exitCost_,
    string calldata name_,
    string calldata symbol_,
    address strategy_
  ) external returns (address) {
    require(asset_ != address(0), "Invalid asset address");
    require(strategy_ != address(0), "Invalid strategy address");
    require(entryCost_ < 0.01 ether, "Entry cost too high");
    require(exitCost_ < 0.01 ether, "Exit cost too high");

    GenesisVault vault = new GenesisVault();

    vault.initialize(msg.sender, asset_, entryCost_, exitCost_, name_, symbol_);

    vault.setStrategy(strategy_);

    VaultInfo memory vaultInfo = VaultInfo({
      vaultAddress: address(vault),
      strategyAddress: strategy_,
      asset: asset_,
      name: name_,
      symbol: symbol_,
      entryCost: entryCost_,
      exitCost: exitCost_,
      owner: msg.sender,
      createdAt: block.timestamp,
      isActive: true
    });

    vaults[address(vault)] = vaultInfo;
    allVaults.push(address(vault));

    emit VaultCreated(address(vault), strategy_, msg.sender, name_, symbol_);

    return address(vault);
  }

  function deactivateVault(address vaultAddress) external {
    VaultInfo storage vaultInfo = vaults[vaultAddress];
    require(vaultInfo.owner == msg.sender, "Not vault owner");
    require(vaultInfo.isActive, "Vault already deactivated");

    vaultInfo.isActive = false;

    emit VaultDeactivated(vaultAddress, msg.sender);
  }

  function getVaultInfo(address vaultAddress) external view returns (VaultInfo memory) {
    return vaults[vaultAddress];
  }

  function getAllVaults() external view returns (address[] memory) {
    return allVaults;
  }

  function getActiveVaults() external view returns (address[] memory) {
    address[] memory activeVaults = new address[](allVaults.length);
    uint256 activeCount = 0;

    for (uint256 i = 0; i < allVaults.length; i++) {
      if (vaults[allVaults[i]].isActive) {
        activeVaults[activeCount] = allVaults[i];
        activeCount++;
      }
    }

    assembly {
      mstore(activeVaults, activeCount)
    }

    return activeVaults;
  }

  function transferVaultOwnership(address vaultAddress, address newOwner) external {
    VaultInfo storage vaultInfo = vaults[vaultAddress];
    require(vaultInfo.owner == msg.sender, "Not vault owner");
    require(newOwner != address(0), "Invalid new owner");

    vaultInfo.owner = newOwner;
  }

  function removeVault(address vaultAddress) external onlyOwner {
    VaultInfo storage vaultInfo = vaults[vaultAddress];
    require(vaultInfo.vaultAddress != address(0), "Vault not found");

    delete vaults[vaultAddress];

    for (uint256 i = 0; i < allVaults.length; i++) {
      if (allVaults[i] == vaultAddress) {
        allVaults[i] = allVaults[allVaults.length - 1];
        allVaults.pop();
        break;
      }
    }
  }
}
