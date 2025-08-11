// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibBaseVolStrike } from "../libraries/LibBaseVolStrike.sol";
import { LibDiamond } from "../libraries/LibDiamond.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPyth } from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { IClearingHouse } from "../interfaces/IClearingHouse.sol";
import { PythLazer } from "../libraries/PythLazer.sol";
import { PriceInfo } from "../types/Types.sol";

contract InitializationFacet {
  using LibBaseVolStrike for LibBaseVolStrike.DiamondStorage;

  uint256 private constant MAX_COMMISSION_FEE = 500; // 5%

  function initialize(
    address _usdcAddress,
    address _oracleAddress,
    address _adminAddress,
    address _operatorAddress,
    uint256 _commissionfee,
    address _clearingHouseAddress,
    uint256 _startTimestamp,
    uint256 _intervalSeconds
  ) public {
    LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
    require(ds.contractOwner == address(0), "Already initialized");

    if (_commissionfee > MAX_COMMISSION_FEE) revert LibBaseVolStrike.InvalidCommissionFee();

    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();

    bvs.token = IERC20(_usdcAddress);
    bvs.oracle = IPyth(_oracleAddress);
    bvs.pythLazer = PythLazer(0xACeA761c27A909d4D3895128EBe6370FDE2dF481);
    bvs.clearingHouse = IClearingHouse(_clearingHouseAddress);
    bvs.adminAddress = _adminAddress;
    bvs.operatorAddress = _operatorAddress;
    bvs.commissionfee = _commissionfee;
    bvs.startTimestamp = _startTimestamp;
    bvs.intervalSeconds = _intervalSeconds;

    // Initialize with default price IDs (BTC/USD and ETH/USD)
    bvs.priceInfos[0] = PriceInfo({
      priceId: 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43,
      productId: 0,
      symbol: "BTC/USD"
    });
    bvs.priceIdToProductId[0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43] = 0;

    bvs.priceInfos[1] = PriceInfo({
      priceId: 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace,
      productId: 1,
      symbol: "ETH/USD"
    });
    bvs.priceIdToProductId[0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace] = 1;

    bvs.priceIdCount = 2;

    // Set the owner of the diamond to the sender
    LibDiamond.setContractOwner(msg.sender);
  }
}
