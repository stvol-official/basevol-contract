// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibBaseVolStrike } from "../libraries/LibBaseVolStrike.sol";
import { LibDiamond } from "../libraries/LibDiamond.sol";
import { PriceInfo, CommissionTier, UserTierInfo } from "../types/Types.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPyth } from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { PythLazer } from "../libraries/PythLazer.sol";

contract AdminFacet {
  using LibBaseVolStrike for LibBaseVolStrike.DiamondStorage;
  using SafeERC20 for IERC20;

  uint256 private constant MAX_COMMISSION_FEE = 5000; // 50%

  event PriceIdAdded(uint256 indexed productId, bytes32 priceId, string symbol);
  event TierCommissionRateSet(CommissionTier indexed tier, uint256 rate);
  event UserTierSet(address indexed user, CommissionTier tier);
  event UserTierRemoved(address indexed user);
  event ETHRetrieved(address indexed admin, uint256 amount);

  modifier onlyOwner() {
    LibDiamond.enforceIsContractOwner();
    _;
  }

  modifier onlyAdmin() {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    require(msg.sender == bvs.adminAddress, "Only admin");
    _;
  }

  modifier onlyOperator() {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    require(msg.sender == bvs.operatorAddress, "Only operator");
    _;
  }

  function transferOwnership(address _newOwner) external onlyOwner {
    if (_newOwner == address(0)) revert LibBaseVolStrike.InvalidAddress();
    LibDiamond.setContractOwner(_newOwner);
  }

  function owner() external view returns (address) {
    return LibDiamond.contractOwner();
  }

  function setPythLazer(address _pythLazer) external onlyAdmin {
    if (_pythLazer == address(0)) revert LibBaseVolStrike.InvalidAddress();
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    bvs.pythLazer = PythLazer(_pythLazer);
  }

  function retrieveMisplacedETH() external onlyAdmin {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    uint256 balance = address(this).balance;
    require(balance > 0, "No ETH to retrieve");

    (bool success, ) = payable(bvs.adminAddress).call{ value: balance }("");
    require(success, "ETH transfer failed");

    emit ETHRetrieved(bvs.adminAddress, balance);
  }

  function retrieveMisplacedTokens(address _token) external onlyAdmin {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    if (address(bvs.token) == _token) revert LibBaseVolStrike.InvalidTokenAddress();
    IERC20 token = IERC20(_token);
    token.safeTransfer(bvs.adminAddress, token.balanceOf(address(this)));
  }

  function setOperator(address _operatorAddress) external onlyAdmin {
    if (_operatorAddress == address(0)) revert LibBaseVolStrike.InvalidAddress();
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    bvs.operatorAddress = _operatorAddress;
  }

  function setOracle(address _oracle) external onlyAdmin {
    if (_oracle == address(0)) revert LibBaseVolStrike.InvalidAddress();
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    bvs.oracle = IPyth(_oracle);
  }

  function setCommissionfee(uint256 _commissionfee) external onlyAdmin {
    if (_commissionfee > MAX_COMMISSION_FEE) revert LibBaseVolStrike.InvalidCommissionFee();
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    bvs.commissionfee = _commissionfee;
  }

  function setAdmin(address _adminAddress) external onlyOwner {
    if (_adminAddress == address(0)) revert LibBaseVolStrike.InvalidAddress();
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    bvs.adminAddress = _adminAddress;
  }

  function setToken(address _token) external onlyAdmin {
    if (_token == address(0)) revert LibBaseVolStrike.InvalidAddress();
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    bvs.token = IERC20(_token);
  }

  function setLastFilledOrderId(uint256 _lastFilledOrderId) external onlyOperator {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    bvs.lastFilledOrderId = _lastFilledOrderId;
  }

  function addPriceId(
    bytes32 _priceId,
    uint256 _productId,
    string calldata _symbol
  ) external onlyOperator {
    _setPriceId(_priceId, _productId, _symbol);
  }

  function initializeDefaultPriceIds() external onlyAdmin {
    _setPriceId(0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43, 0, "BTC/USD");
    _setPriceId(0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace, 1, "ETH/USD");
    _setPriceId(0x44465e17d2e9d390e70c999d5a11fda4f092847fcd2e3e5aa089d96c98a30e67, 2, "XAUT/USD");
    _setPriceId(0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d, 3, "SOL/USD");
    _setPriceId(0xec5d399846a9209f3fe5881d70aae9268c94339ff9817e8d18ff19fa05eea1c8, 4, "XRP/USD");
  }

  function setPriceInfo(PriceInfo calldata priceInfo) external onlyOperator {
    _setPriceId(priceInfo.priceId, priceInfo.productId, priceInfo.symbol);
  }

  /// @dev Idempotent: same productId + priceId as already stored is a no-op. Otherwise upserts like setPriceInfo.
  function _setPriceId(bytes32 _priceId, uint256 _productId, string memory _symbol) internal {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    if (_priceId == bytes32(0)) revert LibBaseVolStrike.InvalidPriceId();
    if (bytes(_symbol).length == 0) revert LibBaseVolStrike.InvalidSymbol();

    if (
      bvs.priceInfos[_productId].priceId == _priceId &&
      keccak256(bytes(bvs.priceInfos[_productId].symbol)) == keccak256(bytes(_symbol))
    ) {
      return;
    }

    uint256 existingProductId = bvs.priceIdToProductId[_priceId];
    if (existingProductId != _productId) {
      if (existingProductId != 0 || bvs.priceInfos[0].priceId == _priceId) {
        revert LibBaseVolStrike.PriceIdAlreadyExists();
      }
    }

    bytes32 oldPriceId = bvs.priceInfos[_productId].priceId;
    if (oldPriceId != bytes32(0)) {
      delete bvs.priceIdToProductId[oldPriceId];
    } else {
      bvs.priceIdCount++;
    }

    bvs.priceInfos[_productId] = PriceInfo({
      priceId: _priceId,
      productId: _productId,
      symbol: _symbol
    });
    bvs.priceIdToProductId[_priceId] = _productId;

    emit PriceIdAdded(_productId, _priceId, _symbol);
  }

  // Tier management functions
  function _validateTier(CommissionTier tier) internal pure {
    if (uint256(tier) > uint256(CommissionTier.ATM_VAULT)) revert LibBaseVolStrike.InvalidTier();
  }

  function setTierCommissionRate(CommissionTier tier, uint256 rate) external onlyOperator {
    if (rate > MAX_COMMISSION_FEE) revert LibBaseVolStrike.InvalidCommissionFee();
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    _validateTier(tier);
    bvs.tierCommissionRates[tier] = rate;
    emit TierCommissionRateSet(tier, rate);
  }

  function setUserTier(address user, CommissionTier tier) external onlyOperator {
    if (user == address(0)) revert LibBaseVolStrike.InvalidAddress();
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    _validateTier(tier);

    if (!bvs.userTierSet[user]) {
      bvs.usersWithTiers.push(user);
    }

    bvs.userTiers[user] = tier;
    bvs.userTierSet[user] = true;
    emit UserTierSet(user, tier);
  }

  function removeUserTier(address user) external onlyOperator {
    if (user == address(0)) revert LibBaseVolStrike.InvalidAddress();
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();

    uint256 length = bvs.usersWithTiers.length;
    for (uint256 i = 0; i < length; i++) {
      if (bvs.usersWithTiers[i] == user) {
        // Move last element to this position and remove last
        bvs.usersWithTiers[i] = bvs.usersWithTiers[length - 1];
        bvs.usersWithTiers.pop();
        break;
      }
    }

    bvs.userTierSet[user] = false;
    emit UserTierRemoved(user);
  }

  function resetAllUserTiers() external onlyOperator {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    uint256 length = bvs.usersWithTiers.length;
    for (uint256 i = 0; i < length; i++) {
      address user = bvs.usersWithTiers[i];
      delete bvs.userTiers[user];
      bvs.userTierSet[user] = false;
    }
    delete bvs.usersWithTiers;
  }

  function getTierCommissionRate(CommissionTier tier) external view returns (uint256) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    return bvs.tierCommissionRates[tier];
  }

  function getCommissionFeeForUser(address user) external view returns (uint256) {
    return LibBaseVolStrike.getCommissionFeeForUser(user);
  }

  function getAllUsersWithTiers() external view returns (UserTierInfo[] memory) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    uint256 length = bvs.usersWithTiers.length;
    UserTierInfo[] memory result = new UserTierInfo[](length);

    for (uint256 i = 0; i < length; i++) {
      address user = bvs.usersWithTiers[i];
      result[i] = UserTierInfo({ user: user, tier: bvs.userTiers[user] });
    }

    return result;
  }
}
