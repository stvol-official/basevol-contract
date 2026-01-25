// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockERC4626
 * @notice Simple ERC4626 vault implementation for testing
 * @dev Uses 1:1 asset:share ratio for simplicity
 */
contract MockERC4626 is ERC4626 {
    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) ERC4626(_asset) {}

    /**
     * @dev Returns decimals matching the underlying asset
     */
    function decimals() public view virtual override returns (uint8) {
        return super.decimals();
    }
}
