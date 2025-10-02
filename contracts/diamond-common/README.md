# Diamond Common

This folder contains the common Diamond Pattern infrastructure used by all Diamond projects.

## 📁 Structure

```
diamond-common/
├── Diamond.sol                # Generic Diamond contract
├── libraries/
│   └── LibDiamond.sol         # Core Diamond logic (EIP-2535)
├── facets/
│   ├── DiamondCutFacet.sol    # Facet management (standard)
│   └── DiamondLoupeFacet.sol  # Diamond introspection (standard)
└── interfaces/
    ├── IDiamondCut.sol        # DiamondCut interface
    └── IDiamondLoupe.sol      # DiamondLoupe interface
```

## 🎯 Purpose

- **Reusable**: Import this folder in all Diamond projects
- **Standards Compliant**: Implements EIP-2535 Diamond Standard
- **Project Independent**: Can be used by BaseVol, GenesisVault, or any other Diamond

## 📚 Usage

### In BaseVol Diamond

```solidity
import { LibDiamond } from "../../diamond-common/libraries/LibDiamond.sol";
import { IDiamondCut } from "../../diamond-common/interfaces/IDiamondCut.sol";
```

### In GenesisVault Diamond

```solidity
import { LibDiamond } from "../../diamond-common/libraries/LibDiamond.sol";
import { IDiamondCut } from "../../diamond-common/interfaces/IDiamondCut.sol";
```

## ⚠️ Important Notes

- **Do not modify** files in this folder (affects all projects)
- If project-specific customization is needed, implement it in the respective project folder
- When upgrading Diamond Pattern, update only this folder to apply changes to all projects

## 🔗 References

- [EIP-2535 Diamond Standard](https://eips.ethereum.org/EIPS/eip-2535)
- [Diamond Pattern Documentation](https://github.com/mudgen/diamond)
