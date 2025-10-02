// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibDiamond } from "../libraries/LibDiamond.sol";
import { IDiamondLoupe } from "../interfaces/IDiamondLoupe.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract DiamondLoupeFacet is IDiamondLoupe, IERC165 {
  /// @notice Gets all facets and their selectors.
  /// @return facets_ Facet
  function facets() external view override returns (Facet[] memory facets_) {
    LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
    uint256 numFacets = ds.selectors.length;
    facets_ = new Facet[](numFacets);
    uint256[] memory numFacetSelectors = new uint256[](numFacets);
    uint256 numFacetsIndex = 0;

    for (uint256 selectorIndex; selectorIndex < numFacets; selectorIndex++) {
      bytes4 selector = ds.selectors[selectorIndex];
      address facetAddress_ = ds.facetAddressAndSelectorPosition[selector].facetAddress;
      bool continueLoop = false;

      for (uint256 facetIndex; facetIndex < numFacetsIndex; facetIndex++) {
        if (facets_[facetIndex].facetAddress == facetAddress_) {
          facets_[facetIndex].functionSelectors[numFacetSelectors[facetIndex]] = selector;
          numFacetSelectors[facetIndex]++;
          continueLoop = true;
          break;
        }
      }

      if (continueLoop) {
        continue;
      }

      facets_[numFacetsIndex].facetAddress = facetAddress_;
      facets_[numFacetsIndex].functionSelectors = new bytes4[](numFacets);
      facets_[numFacetsIndex].functionSelectors[0] = selector;
      numFacetSelectors[numFacetsIndex] = 1;
      numFacetsIndex++;
    }

    for (uint256 facetIndex; facetIndex < numFacetsIndex; facetIndex++) {
      uint256 numSelectors = numFacetSelectors[facetIndex];
      bytes4[] memory selectors = facets_[facetIndex].functionSelectors;

      // setting the number of selectors
      assembly {
        mstore(selectors, numSelectors)
      }
    }

    // setting the number of facets
    assembly {
      mstore(facets_, numFacetsIndex)
    }
  }

  /// @notice Gets all the function selectors supported by a specific facet.
  /// @param _facet The facet address.
  /// @return facetFunctionSelectors_
  function facetFunctionSelectors(
    address _facet
  ) external view override returns (bytes4[] memory facetFunctionSelectors_) {
    LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
    uint256 numSelectors = ds.selectors.length;
    facetFunctionSelectors_ = new bytes4[](numSelectors);
    uint256 numFacetSelectors = 0;

    for (uint256 selectorIndex; selectorIndex < numSelectors; selectorIndex++) {
      bytes4 selector = ds.selectors[selectorIndex];
      address facetAddress_ = ds.facetAddressAndSelectorPosition[selector].facetAddress;

      if (facetAddress_ == _facet) {
        facetFunctionSelectors_[numFacetSelectors] = selector;
        numFacetSelectors++;
      }
    }

    // Set the number of selectors in the array
    assembly {
      mstore(facetFunctionSelectors_, numFacetSelectors)
    }
  }

  /// @notice Get all the facet addresses used by a diamond.
  /// @return facetAddresses_
  function facetAddresses() external view override returns (address[] memory facetAddresses_) {
    LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
    uint256 numFacets = ds.selectors.length;
    facetAddresses_ = new address[](numFacets);
    uint256 numFacetsIndex = 0;

    for (uint256 selectorIndex; selectorIndex < numFacets; selectorIndex++) {
      bytes4 selector = ds.selectors[selectorIndex];
      address facetAddress_ = ds.facetAddressAndSelectorPosition[selector].facetAddress;
      bool continueLoop = false;

      for (uint256 facetIndex; facetIndex < numFacetsIndex; facetIndex++) {
        if (facetAddress_ == facetAddresses_[facetIndex]) {
          continueLoop = true;
          break;
        }
      }

      if (continueLoop) {
        continue;
      }

      facetAddresses_[numFacetsIndex] = facetAddress_;
      numFacetsIndex++;
    }

    // Set the number of facet addresses in the array
    assembly {
      mstore(facetAddresses_, numFacetsIndex)
    }
  }

  /// @notice Gets the facet that supports the given selector.
  /// @dev If facet is not found return address(0).
  /// @param _functionSelector The function selector.
  /// @return facetAddress_ The facet address.
  function facetAddress(
    bytes4 _functionSelector
  ) external view override returns (address facetAddress_) {
    LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
    facetAddress_ = ds.facetAddressAndSelectorPosition[_functionSelector].facetAddress;
  }

  /// @notice Query if a contract implements an interface
  /// @param interfaceId The interface identifier, as specified in ERC-165
  /// @dev Interface identification is specified in ERC-165. This function
  ///  uses less than 30,000 gas.
  /// @return `true` if the contract implements `interfaceId` and
  ///  `interfaceId` is not 0xffffffff, `false` otherwise
  function supportsInterface(bytes4 interfaceId) external view override returns (bool) {
    LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
    return ds.supportedInterfaces[interfaceId];
  }
}
