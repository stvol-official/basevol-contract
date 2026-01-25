// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibDiamond } from "../libraries/LibDiamond.sol";
import { IDiamondCut } from "../interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../interfaces/IDiamondLoupe.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC173 } from "../interfaces/IERC173.sol";

/**
 * @title NexusVaultDiamond
 * @author BaseVol Team
 * @notice Diamond proxy contract for NexusVault ERC4626 meta-vault
 * @dev Implements EIP-2535 Diamond Standard for modular, upgradeable architecture
 *
 * Key features:
 * - Modular facet-based architecture
 * - Upgradeable without storage collisions
 * - Immutable core functions (optional)
 * - Gas-efficient function routing
 *
 * This diamond aggregates multiple ERC4626 vaults into a single interface,
 * providing weight-based allocation, automatic rebalancing, and fee management.
 */
contract NexusVaultDiamond {
    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the Diamond with initial facets
     * @param _contractOwner Address that will own the diamond
     * @param _diamondCut Initial facet cuts to apply
     *
     * The constructor:
     * 1. Sets the contract owner in diamond storage
     * 2. Applies initial facet cuts (adds function selectors)
     * 3. Registers supported interfaces (ERC165)
     */
    constructor(
        address _contractOwner,
        IDiamondCut.FacetCut[] memory _diamondCut
    ) payable {
        // Set the contract owner
        LibDiamond.setContractOwner(_contractOwner);

        // Apply initial diamond cut
        LibDiamond.diamondCut(_diamondCut, address(0), "");

        // Register supported interfaces
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();

        // ERC165
        ds.supportedInterfaces[type(IERC165).interfaceId] = true;

        // ERC173 (Ownership)
        ds.supportedInterfaces[type(IERC173).interfaceId] = true;

        // IDiamondCut
        ds.supportedInterfaces[type(IDiamondCut).interfaceId] = true;

        // IDiamondLoupe
        ds.supportedInterfaces[type(IDiamondLoupe).interfaceId] = true;
    }

    /*//////////////////////////////////////////////////////////////
                            FALLBACK
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Route calls to appropriate facet
     * @dev Uses delegatecall to execute facet code in diamond's storage context
     *
     * Flow:
     * 1. Extract function selector from calldata
     * 2. Look up facet address for selector
     * 3. Revert if no facet found
     * 4. Delegatecall to facet
     * 5. Return or revert based on call result
     */
    fallback() external payable {
        LibDiamond.DiamondStorage storage ds;
        bytes32 position = LibDiamond.DIAMOND_STORAGE_POSITION;

        // Get diamond storage
        assembly {
            ds.slot := position
        }

        // Get facet address for function selector
        address facet = ds.facetAddressAndSelectorPosition[msg.sig].facetAddress;

        // Revert if function doesn't exist
        require(facet != address(0), "Diamond: Function does not exist");

        // Execute external function from facet using delegatecall
        assembly {
            // Copy function selector and arguments to memory
            calldatacopy(0, 0, calldatasize())

            // Execute delegatecall
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)

            // Copy return data to memory
            returndatacopy(0, 0, returndatasize())

            // Return or revert based on result
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            RECEIVE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Accept ETH transfers
     * @dev Required for potential ETH operations or wrapped ETH vaults
     */
    receive() external payable {}
}
