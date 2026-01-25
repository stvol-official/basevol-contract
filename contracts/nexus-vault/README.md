# NexusVault Diamond Implementation

NexusVault is a synchronous ERC4626 Meta-Vault that aggregates multiple ERC4626 vaults using the EIP-2535 Diamond Pattern.

## 📋 Table of Contents

- [Key Features](#key-features)
- [Architecture](#architecture)
- [Facets Overview](#facets-overview)
- [Usage](#usage)
- [Deployment](#deployment)
- [Security](#security)

## Key Features

### Standard Compliance

- **ERC-4626**: Tokenized Vault Standard (Synchronous)
- **ERC-20**: Standard token transfers and approvals
- **EIP-2535**: Diamond Pattern for modular architecture

### Core Capabilities

- ✅ **Multi-Vault Aggregation**: Combine multiple ERC4626 vaults under one interface
- ✅ **Weight-based Allocation**: Configure target allocation percentages per vault
- ✅ **Automatic Rebalancing**: Keeper-triggered portfolio rebalancing
- ✅ **Fee System**: Management fees, performance fees (High Water Mark), deposit/withdraw fees
- ✅ **Access Control**: Owner, Admin, Keeper role hierarchy

## Architecture

### Diamond Storage Pattern

All state variables are managed in a single storage structure in `LibNexusVaultStorage.sol`. This prevents storage collisions between facets and ensures upgrade safety.

```solidity
// Diamond Storage Position
bytes32 constant DIAMOND_STORAGE_POSITION = keccak256("nexus.vault.diamond.storage");
```

**⚠️ CRITICAL**: Never modify the order or types of existing storage variables. New variables must always be appended at the end of the struct.

### Project Structure

```
contracts/nexus-vault/
├── facets/
│   ├── NexusVaultInitFacet.sol      # Initialization
│   ├── NexusVaultCoreFacet.sol      # ERC4626 operations
│   ├── NexusVaultAdminFacet.sol     # Admin functions
│   ├── NexusVaultRebalanceFacet.sol # Rebalancing
│   ├── NexusVaultViewFacet.sol      # View functions
│   └── ERC20Facet.sol               # ERC20 token
├── libraries/
│   ├── LibNexusVaultStorage.sol     # Diamond Storage
│   ├── LibNexusVaultAuth.sol        # Access control
│   └── LibNexusVault.sol            # Calculation logic
├── interfaces/
│   └── INexusVault.sol              # Main interface
├── errors/
│   └── NexusVaultErrors.sol         # Custom errors
└── README.md
```

## Facets Overview

### 1. NexusVaultInitFacet

**Role**: One-time initialization

**Key Functions**:

- `initialize(asset, name, symbol, admin, feeRecipient)`: Initialize vault
- `addInitialKeepers(keepers)`: Add initial keeper addresses

### 2. ERC20Facet

**Role**: Standard ERC-20 token functionality

**Key Functions**:

- `transfer(to, amount)`: Transfer shares
- `approve(spender, amount)`: Approve spending
- `transferFrom(from, to, amount)`: Transfer on behalf
- `balanceOf(account)`: Query balance
- `totalSupply()`: Query total supply

### 3. NexusVaultCoreFacet (Phase 2)

**Role**: ERC4626 vault operations

**Key Functions**:

- `deposit(assets, receiver)`: Deposit assets, receive shares
- `withdraw(assets, receiver, owner)`: Withdraw assets
- `mint(shares, receiver)`: Mint exact shares
- `redeem(shares, receiver, owner)`: Redeem shares for assets

### 4. NexusVaultAdminFacet (Phase 3)

**Role**: Vault management and configuration

**Key Functions**:

- `addVault(vault, weights)`: Add underlying vault
- `removeVault(vault)`: Remove vault
- `setFees(...)`: Configure fees
- `pause()` / `unpause()`: Emergency controls

### 5. NexusVaultRebalanceFacet (Phase 3)

**Role**: Portfolio rebalancing

**Key Functions**:

- `rebalance()`: Execute full rebalancing
- `needsRebalance()`: Check if rebalancing is needed

### 6. NexusVaultViewFacet (Phase 2)

**Role**: Read-only queries

**Key Functions**:

- `totalAssets()`: Total assets under management
- `convertToShares(assets)`: Convert assets to shares
- `getVaults()`: List all vaults
- `getAllocationStatus()`: Current vs target allocation

## Security

### Access Control

| Role | Permissions |
|------|-------------|
| **Owner** | Diamond upgrades, set admin, shutdown, emergency withdraw |
| **Admin** | Configure vaults, fees, limits, keepers, pause/unpause |
| **Keeper** | Trigger rebalancing, collect fees |
| **User** | Deposit, withdraw, transfer shares |

### Security Features

1. **Reentrancy Protection**: All state-changing functions protected
2. **Pause Mechanism**: Emergency halt of all operations
3. **Shutdown Mode**: Permanent disable of deposits (withdrawals allowed)
4. **Fee Limits**: Maximum caps on all fee types
5. **Diamond Storage Pattern**: Prevents storage collisions

## Development Status

- [x] Phase 1: Core Infrastructure (Storage, Auth, Init, ERC20)
- [x] Phase 2: ERC4626 Core (deposit, withdraw, mint, redeem)
- [x] Phase 3: Multi-Vault & Rebalancing (Admin, Fee, Rebalance)
- [x] Phase 4: Diamond & Deployment Scripts
- [x] Phase 5: Testing & Documentation

## Testing

Run the test suite:

```bash
npx hardhat test test/nexus-vault/NexusVault.test.ts
```

Test coverage includes:
- Diamond deployment and initialization
- ERC20 functionality
- ERC4626 vault operations
- Multi-vault management
- Access control
- Emergency controls
- Fee configuration

## Deployment

Deploy to testnet:
```bash
npx hardhat run --network base_sepolia scripts/nexus-vault/deploy-nexus-vault-diamond.ts
```

Deploy to mainnet:
```bash
npx hardhat run --network base scripts/nexus-vault/deploy-nexus-vault-diamond.ts
```

Generate combined ABI:
```bash
npx hardhat run scripts/nexus-vault/generate-nexus-vault-abi.ts
```

---

**Version**: 1.0.0  
**Status**: ✅ Development Complete
