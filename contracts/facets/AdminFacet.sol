// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibBaseVolStrike } from "../libraries/LibBaseVolStrike.sol";
import { LibDiamond } from "../libraries/LibDiamond.sol";
import { PriceInfo } from "../types/Types.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPyth } from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { PythLazer } from "../libraries/PythLazer.sol";

contract AdminFacet {
  using LibBaseVolStrike for LibBaseVolStrike.DiamondStorage;
  using SafeERC20 for IERC20;

  uint256 private constant MAX_COMMISSION_FEE = 5000; // 50%

  event PriceIdAdded(uint256 indexed productId, bytes32 priceId, string symbol);

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

  modifier onlyOwner() {
    LibDiamond.enforceIsContractOwner();
    _;
  }

  function setPythLazer(address _pythLazer) external onlyAdmin {
    if (_pythLazer == address(0)) revert LibBaseVolStrike.InvalidAddress();
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    bvs.pythLazer = PythLazer(_pythLazer);
  }

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

  // Internal function
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
}
