// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPyth } from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { BaseVolStrikeStorage } from "../storage/BaseVolStrikeStorage.sol";
import { PriceInfo } from "../types/Types.sol";
library AdminLib {
  using SafeERC20 for IERC20;

  error InvalidAddress();
  error InvalidCommissionFee();
  error InvalidTokenAddress();
  error InvalidPriceId();
  error PriceIdAlreadyExists();
  error ProductIdAlreadyExists();
  error InvalidSymbol();

  event PriceIdAdded(uint256 indexed productId, bytes32 priceId, string symbol);

  function setOperator(BaseVolStrikeStorage.Layout storage $, address _operatorAddress) internal {
    if (_operatorAddress == address(0)) revert InvalidAddress();
    $.operatorAddress = _operatorAddress;
  }

  function setOracle(BaseVolStrikeStorage.Layout storage $, address _oracle) internal {
    if (_oracle == address(0)) revert InvalidAddress();
    $.oracle = IPyth(_oracle);
  }

  function setCommissionfee(
    BaseVolStrikeStorage.Layout storage $,
    uint256 _commissionfee
  ) internal {
    uint256 MAX_COMMISSION_FEE = 500;
    if (_commissionfee > MAX_COMMISSION_FEE) revert InvalidCommissionFee();
    $.commissionfee = _commissionfee;
  }

  function setAdmin(BaseVolStrikeStorage.Layout storage $, address _adminAddress) internal {
    if (_adminAddress == address(0)) revert InvalidAddress();
    $.adminAddress = _adminAddress;
  }

  function setToken(BaseVolStrikeStorage.Layout storage $, address _token) internal {
    if (_token == address(0)) revert InvalidAddress();
    $.token = IERC20(_token);
  }

  function retrieveMisplacedETH(
    BaseVolStrikeStorage.Layout storage $,
    address contractAddress
  ) internal {
    payable($.adminAddress).transfer(contractAddress.balance);
  }

  function retrieveMisplacedTokens(
    BaseVolStrikeStorage.Layout storage $,
    address _token,
    address contractAddress
  ) internal {
    if (address($.token) == _token) revert InvalidTokenAddress();
    IERC20 token = IERC20(_token);
    token.safeTransfer($.adminAddress, token.balanceOf(contractAddress));
  }

  function addPriceId(
    BaseVolStrikeStorage.Layout storage $,
    bytes32 _priceId,
    uint256 _productId,
    string memory _symbol
  ) internal {
    if (_priceId == bytes32(0)) revert InvalidPriceId();
    if ($.priceIdToProductId[_priceId] != 0 || $.priceInfos[0].priceId == _priceId) {
      revert PriceIdAlreadyExists();
    }
    if ($.priceInfos[_productId].priceId != bytes32(0)) {
      revert ProductIdAlreadyExists();
    }
    if (bytes(_symbol).length == 0) {
      revert InvalidSymbol();
    }

    $.priceInfos[_productId] = PriceInfo({
      priceId: _priceId,
      productId: _productId,
      symbol: _symbol
    });

    $.priceIdToProductId[_priceId] = _productId;
    $.priceIdCount++;

    emit PriceIdAdded(_productId, _priceId, _symbol);
  }

  function setPriceInfo(
    BaseVolStrikeStorage.Layout storage $,
    PriceInfo calldata priceInfo
  ) internal {
    if (priceInfo.priceId == bytes32(0)) revert InvalidPriceId();
    if (bytes(priceInfo.symbol).length == 0) revert InvalidSymbol();

    uint256 existingProductId = $.priceIdToProductId[priceInfo.priceId];
    bytes32 oldPriceId = $.priceInfos[priceInfo.productId].priceId;

    if (existingProductId != priceInfo.productId) {
      if (existingProductId != 0 || $.priceInfos[0].priceId == priceInfo.priceId) {
        revert PriceIdAlreadyExists();
      }
    }

    if (oldPriceId != bytes32(0)) {
      delete $.priceIdToProductId[oldPriceId];
    }

    $.priceInfos[priceInfo.productId] = priceInfo;
    $.priceIdToProductId[priceInfo.priceId] = priceInfo.productId;

    emit PriceIdAdded(priceInfo.productId, priceInfo.priceId, priceInfo.symbol);
  }

  function setRedeemFee(BaseVolStrikeStorage.Layout storage $, uint256 _redeemFee) internal {
    $.redeemFee = _redeemFee;
  }

  function setRedeemVault(BaseVolStrikeStorage.Layout storage $, address _redeemVault) internal {
    $.redeemVault = _redeemVault;
  }
}
