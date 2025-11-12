// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibDiamond } from "../libraries/LibDiamond.sol";
import { IDiamondLoupe } from "../interfaces/IDiamondLoupe.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract DiamondLoupeFacet is IDiamondLoupe, IERC165 {
  /// @notice Gets facets with pagination support
  /// @param startIndex Starting selector index
  /// @param maxResults Maximum number of selectors to process
  /// @return facets_ Facet array
  /// @return totalSelectors Total number of selectors
  /// @return nextIndex Next page start index (0 if last page)
  function facetsPaginated(
    uint256 startIndex,
    uint256 maxResults
  ) 
    external 
    view 
    returns (
      Facet[] memory facets_,
      uint256 totalSelectors,
      uint256 nextIndex
    ) 
  {
    require(maxResults > 0 && maxResults <= 200, "Invalid page size");
    
    LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
    totalSelectors = ds.selectors.length;
    
    // Return empty if start index is out of bounds
    if (startIndex >= totalSelectors) {
      return (new Facet[](0), totalSelectors, 0);
    }
    
    // Calculate end index
    uint256 endIndex = startIndex + maxResults;
    if (endIndex > totalSelectors) {
      endIndex = totalSelectors;
    }
    
    // Temporary array to track unique facets
    address[] memory uniqueFacets = new address[](endIndex - startIndex);
    uint256 uniqueCount = 0;
    
    // First pass: collect unique facet addresses
    for (uint256 i = startIndex; i < endIndex; i++) {
      bytes4 selector = ds.selectors[i];
      address facetAddress_ = ds.facetAddressAndSelectorPosition[selector].facetAddress;
      
      // Check for duplicates
      bool isDuplicate = false;
      for (uint256 j = 0; j < uniqueCount; j++) {
        if (uniqueFacets[j] == facetAddress_) {
          isDuplicate = true;
          break;
        }
      }
      
      if (!isDuplicate) {
        uniqueFacets[uniqueCount] = facetAddress_;
        uniqueCount++;
      }
    }
    
    // Create facets array
    facets_ = new Facet[](uniqueCount);
    uint256[] memory selectorCounts = new uint256[](uniqueCount);
    
    // Initialize facets
    for (uint256 i = 0; i < uniqueCount; i++) {
      facets_[i].facetAddress = uniqueFacets[i];
      facets_[i].functionSelectors = new bytes4[](endIndex - startIndex);
    }
    
    // Second pass: collect selectors
    for (uint256 i = startIndex; i < endIndex; i++) {
      bytes4 selector = ds.selectors[i];
      address facetAddress_ = ds.facetAddressAndSelectorPosition[selector].facetAddress;
      
      // Find facet index
      for (uint256 j = 0; j < uniqueCount; j++) {
        if (uniqueFacets[j] == facetAddress_) {
          facets_[j].functionSelectors[selectorCounts[j]] = selector;
          selectorCounts[j]++;
          break;
        }
      }
    }
    
    // Resize selector arrays
    for (uint256 i = 0; i < uniqueCount; i++) {
      bytes4[] memory selectors = facets_[i].functionSelectors;
      assembly {
        mstore(selectors, mload(add(selectorCounts, mul(add(i, 1), 0x20))))
      }
    }
    
    // Calculate next index
    nextIndex = endIndex < totalSelectors ? endIndex : 0;
    
    return (facets_, totalSelectors, nextIndex);
  }

  /// @notice Gets all facets and their selectors (backward compatible, limited to 200 selectors)
  /// @return facets_ Facet
  function facets() external view override returns (Facet[] memory facets_) {
    LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
    uint256 numSelectors = ds.selectors.length;
    
    // Protect against gas limit with large selector count
    require(numSelectors <= 200, "Too many selectors, use facetsPaginated");
    
    (facets_,,) = this.facetsPaginated(0, numSelectors);
    return facets_;
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

  /// @notice Get total number of selectors
  /// @return count The selector count
  function selectorCount() external view returns (uint256 count) {
    LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
    return ds.selectors.length;
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
