// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibDiamond } from "../libraries/LibDiamond.sol";
import { IDiamondLoupe } from "../interfaces/IDiamondLoupe.sol";
import { IDiamondCut } from "../interfaces/IDiamondCut.sol";
import { IERC173 } from "../interfaces/IERC173.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { LibBaseVolStrike } from "../libraries/LibBaseVolStrike.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPyth } from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { IClearingHouse } from "../interfaces/IClearingHouse.sol";
import { PythLazer } from "../libraries/PythLazer.sol";
import { PriceInfo } from "../types/Types.sol";

// It is expected that this contract is customized if you want to deploy your diamond
// with data from a deployment script. Use the init function to initialize state variables
// of your diamond. Add parameters to the init function if you need to.

contract DiamondInit {
  // You can add parameters to this function in order to pass in
  // data to set your own state variables
  function init(
    address _usdcAddress,
    address _oracleAddress,
    address _adminAddress,
    address _operatorAddress,
    uint256 _commissionfee,
    address _clearingHouseAddress,
    uint256 _startTimestamp,
    uint256 _intervalSeconds
  ) external {
    // adding ERC165 data
    LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
    ds.supportedInterfaces[type(IERC165).interfaceId] = true;
    ds.supportedInterfaces[type(IDiamondCut).interfaceId] = true;
    ds.supportedInterfaces[type(IDiamondLoupe).interfaceId] = true;
    ds.supportedInterfaces[type(IERC173).interfaceId] = true;

    // Initialize BaseVolStrike storage
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();

    bvs.token = IERC20(_usdcAddress);
    bvs.oracle = IPyth(_oracleAddress);
    bvs.pythLazer = PythLazer(0xACeA761c27A909d4D3895128EBe6370FDE2dF481);
    bvs.clearingHouse = IClearingHouse(_clearingHouseAddress);
    bvs.adminAddress = _adminAddress;
    bvs.operatorAddress = _operatorAddress;
    bvs.commissionfee = _commissionfee;

    // Set time configuration
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

    // add your own state variables
    // EIP-2535 specifies that the `diamondCut` function takes two optional
    // arguments: address _init and bytes calldata _calldata
    // These arguments are used to execute an arbitrary function using delegatecall
    // in order to set state variables in the diamond during deployment or an upgrade
    // More info here: https://eips.ethereum.org/EIPS/eip-2535#diamond-interface
  }
}
