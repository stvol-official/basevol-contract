// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title MockMetaMorpho
/// @notice Mock Morpho Vault for testing MorphoVaultManager
/// @dev Implements a simplified ERC4626 interface
contract MockMetaMorpho is ERC20 {
  using SafeERC20 for IERC20;

  IERC20 public immutable _asset;
  uint8 private constant DECIMALS_OFFSET = 0;

  // 1:1 exchange rate for simplicity (can be modified for yield simulation)
  uint256 public exchangeRate = 1e18; // 1 share = 1 asset

  constructor(address asset_) ERC20("Mock Morpho Vault", "mMORPHO") {
    _asset = IERC20(asset_);
  }

  function asset() external view returns (address) {
    return address(_asset);
  }

  function totalAssets() public view returns (uint256) {
    return _asset.balanceOf(address(this));
  }

  function convertToShares(uint256 assets) public view returns (uint256) {
    return (assets * 1e18) / exchangeRate;
  }

  function convertToAssets(uint256 shares) public view returns (uint256) {
    return (shares * exchangeRate) / 1e18;
  }

  function maxDeposit(address) external pure returns (uint256) {
    return type(uint256).max;
  }

  function maxMint(address) external pure returns (uint256) {
    return type(uint256).max;
  }

  function maxWithdraw(address owner_) external view returns (uint256) {
    return convertToAssets(balanceOf(owner_));
  }

  function maxRedeem(address owner_) external view returns (uint256) {
    return balanceOf(owner_);
  }

  function previewDeposit(uint256 assets) external view returns (uint256) {
    return convertToShares(assets);
  }

  function previewMint(uint256 shares) external view returns (uint256) {
    return convertToAssets(shares);
  }

  function previewWithdraw(uint256 assets) external view returns (uint256) {
    return convertToShares(assets);
  }

  function previewRedeem(uint256 shares) external view returns (uint256) {
    return convertToAssets(shares);
  }

  function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
    shares = convertToShares(assets);
    _asset.safeTransferFrom(msg.sender, address(this), assets);
    _mint(receiver, shares);
  }

  function mint(uint256 shares, address receiver) external returns (uint256 assets) {
    assets = convertToAssets(shares);
    _asset.safeTransferFrom(msg.sender, address(this), assets);
    _mint(receiver, shares);
  }

  function withdraw(
    uint256 assets,
    address receiver,
    address owner_
  ) external returns (uint256 shares) {
    shares = convertToShares(assets);

    if (msg.sender != owner_) {
      uint256 allowed = allowance(owner_, msg.sender);
      if (allowed != type(uint256).max) {
        _approve(owner_, msg.sender, allowed - shares);
      }
    }

    _burn(owner_, shares);
    _asset.safeTransfer(receiver, assets);
  }

  function redeem(
    uint256 shares,
    address receiver,
    address owner_
  ) external returns (uint256 assets) {
    if (msg.sender != owner_) {
      uint256 allowed = allowance(owner_, msg.sender);
      if (allowed != type(uint256).max) {
        _approve(owner_, msg.sender, allowed - shares);
      }
    }

    assets = convertToAssets(shares);
    _burn(owner_, shares);
    _asset.safeTransfer(receiver, assets);
  }

  // Test helper: simulate yield by increasing exchange rate
  function simulateYield(uint256 yieldBps) external {
    // yieldBps: 100 = 1%
    exchangeRate = (exchangeRate * (10000 + yieldBps)) / 10000;
  }

  // Test helper: set exact exchange rate
  function setExchangeRate(uint256 newRate) external {
    exchangeRate = newRate;
  }

  // ERC4626 required functions
  function decimals() public pure override returns (uint8) {
    return 18;
  }
}
