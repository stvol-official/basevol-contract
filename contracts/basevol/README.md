# BaseVol Diamond

Diamond Pattern implementation for the BaseVol prediction market system.

## 📁 Structure

```
basevol/
├── libraries/
│   └── LibBaseVolStrike.sol   # BaseVol Storage & Logic
├── facets/
│   ├── BaseVolAdminFacet.sol          # Admin functions
│   ├── BaseVolViewFacet.sol           # View functions
│   ├── OrderProcessingFacet.sol       # Order processing
│   ├── RedemptionFacet.sol            # Redemption logic
│   ├── RoundManagementFacet.sol       # Round management
│   └── InitializationFacet.sol        # Initialization
└── interfaces/
    └── (to be added)
```

## 🎯 Purpose

- **BaseVolOneDay**: 1-day prediction market
- **BaseVolOneHour**: 1-hour prediction market
- **Independent**: Completely separated from GenesisVault

## 🔗 Dependencies

### Common Diamond Infrastructure

```solidity
import { LibDiamond } from "../../diamond-common/libraries/LibDiamond.sol";
```

### Common Types & Interfaces

```solidity
import { Round, FilledOrder } from "../../types/Types.sol";
import { IClearingHouse } from "../../interfaces/IClearingHouse.sol";
```

## 📝 Deployment

```typescript
// See scripts/basevol/deploy-basevol-diamond.ts
import { ethers } from "hardhat";

// 1. Deploy common Diamond
const Diamond = await ethers.getContractFactory("contracts/diamond-common/Diamond.sol:Diamond");

// 2. Deploy BaseVol Facets
const OrderProcessingFacet = await ethers.getContractFactory(
  "contracts/basevol/facets/OrderProcessingFacet.sol:OrderProcessingFacet",
);
```

## ⚠️ Important Notes

- Facet names must have "BaseVol" prefix to distinguish from GenesisVault
- `LibBaseVolStrike` is BaseVol-specific Storage (do not use in other projects)

## 🚀 Future Plans

- [ ] Add BaseVol-specific interfaces
- [ ] Optimize storage
- [ ] Develop additional facets
