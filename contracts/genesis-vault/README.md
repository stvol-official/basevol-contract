# GenesisVault Diamond Implementation

GenesisVault is an asynchronous vault implementing the ERC-7540 standard using the EIP-2535 Diamond Pattern, with epoch-based settlement synchronized to BaseVol rounds.

## 📋 Table of Contents

- [Key Features](#key-features)
- [Architecture](#architecture)
- [Facets Overview](#facets-overview)
- [Usage](#usage)
- [Deployment](#deployment)
- [Security](#security)
- [Integration](#integration)

## Key Features

### Standard Compliance

- **ERC-7540**: Asynchronous Tokenized Vaults
- **ERC-4626**: Tokenized Vault Standard
- **ERC-20**: Standard token transfers and approvals
- **EIP-2535**: Diamond Pattern for modular architecture

### Core Capabilities

- ✅ **Epoch-based Settlement**: Asynchronous deposits/withdrawals synchronized with BaseVol rounds
- ✅ **Auto-processing**: Automatic user request processing during settlement
- ✅ **WAEP-based Performance Fees**: Per-user Weighted Average Entry Price tracking
- ✅ **Multi-tier Fee Structure**: Management fees, performance fees, entry/exit costs
- ✅ **Strategy Integration**: Asset allocation and yield generation via GenesisStrategy
- ✅ **Liquidity Management**: Intelligent liquidity provision for withdrawals

## Architecture

### Diamond Storage Pattern

All state variables are managed in a single storage structure in `LibGenesisVaultStorage.sol`. This prevents storage collisions between facets and ensures upgrade safety.

```solidity
// Diamond Storage Position
bytes32 constant DIAMOND_STORAGE_POSITION = keccak256("genesis.vault.diamond.storage");
```

**⚠️ CRITICAL**: Never modify the order or types of existing storage variables. New variables must always be appended at the end of the struct.

### Storage Structure

```solidity
struct Layout {
    // Core Vault State
    IERC20 asset;              // Underlying asset (e.g., USDC)
    string name;               // Vault name
    string symbol;             // Vault symbol
    uint8 decimals;            // Decimals
    uint256 totalSupply;       // Total share supply
    mapping(address => uint256) balances;         // User share balances
    mapping(address => mapping(address => uint256)) allowances;  // ERC20 allowances

    // Access Control
    address owner;             // Contract owner
    address admin;             // Admin address
    address[] keepers;         // Keeper list

    // Integration Addresses
    address baseVolContract;   // BaseVol contract address
    address strategy;          // Strategy contract address

    // ERC7540 Operator System
    mapping(address => mapping(address => bool)) operators;

    // Round/Epoch Management
    mapping(uint256 => RoundData) roundData;

    // Deposit Tracking (epoch-based)
    mapping(address => mapping(uint256 => uint256)) userEpochDepositAssets;
    mapping(address => mapping(uint256 => uint256)) userEpochClaimedDepositAssets;
    mapping(address => uint256[]) userDepositEpochs;

    // Redeem Tracking (epoch-based)
    mapping(address => mapping(uint256 => uint256)) userEpochRedeemShares;
    mapping(address => mapping(uint256 => uint256)) userEpochClaimedRedeemShares;
    mapping(address => uint256[]) userRedeemEpochs;

    // Auto-Processing Tracking
    mapping(uint256 => address[]) epochDepositUsers;
    mapping(uint256 => address[]) epochRedeemUsers;

    // Fee Management
    uint256 managementFee;     // Annual management fee in 1e18 precision (e.g., 0.02 * 1e18 = 2%)
    uint256 performanceFee;    // Performance fee in 1e18 precision (e.g., 0.20 * 1e18 = 20%)
    uint256 hurdleRate;        // Minimum return threshold in 1e18 precision (e.g., 0.05 * 1e18 = 5%)
    uint256 entryCost;         // Entry cost in asset decimals (e.g., 1e6 = 1 USDC)
    uint256 exitCost;          // Exit cost in asset decimals (e.g., 1e6 = 1 USDC)
    address feeRecipient;      // Fee recipient address

    // User Performance Tracking
    mapping(address => UserPerformanceData) userPerformanceData;
    ManagementFeeData managementFeeData;

    // Limits & Controls
    uint256 userDepositLimit;  // Maximum deposit per user
    uint256 vaultDepositLimit; // Maximum total vault deposits
    bool shutdown;             // Shutdown state
    bool paused;               // Paused state
}
```

## Facets Overview

GenesisVault consists of 7 facets, each responsible for specific functionality.

### 1. ERC20Facet

**Role**: Standard ERC-20 token functionality

**Key Functions**:

- `transfer(to, amount)`: Transfer shares
- `approve(spender, amount)`: Approve spending
- `transferFrom(from, to, amount)`: Transfer on behalf
- `balanceOf(account)`: Query balance
- `totalSupply()`: Query total supply
- `name()`, `symbol()`, `decimals()`: Token metadata

### 2. GenesisVaultViewFacet

**Role**: All read-only functions and state queries

**Key Functions**:

- `asset()`: Underlying asset address
- `totalAssets()`: Total assets (idle + strategy - claimable withdrawals)
- `idleAssets()`: Idle assets (settled assets only)
- `convertToAssets(shares)`: Convert shares → assets
- `convertToShares(assets)`: Convert assets → shares
- `getCurrentEpoch()`: Current epoch number
- `roundData(epoch)`: Settlement data per epoch
- `maxDeposit(receiver)`: Maximum claimable deposit amount
- `maxRedeem(controller)`: Maximum claimable redeem shares
- `maxRequestDeposit(receiver)`: Maximum requestable deposit amount
- `maxRequestRedeem(owner)`: Maximum requestable redeem shares
- `getUserPerformanceData(user)`: User WAEP data
- `totalClaimableWithdraw()`: Total claimable withdrawal amount

**ERC7540 Request State Functions**:

- `pendingDepositRequest(requestId, controller)`: Pending deposit assets
- `claimableDepositRequest(requestId, controller)`: Claimable deposit assets
- `pendingRedeemRequest(requestId, controller)`: Pending redeem shares
- `claimableRedeemRequest(requestId, controller)`: Claimable redeem shares

**Note**:

- For ERC7540 async vaults, `previewDeposit`, `previewMint`, `previewWithdraw`, `previewRedeem` always revert.
- `requestId` equals the epoch number.

### 3. VaultCoreFacet

**Role**: Core vault operations (ERC7540 async deposits/withdrawals)

**ERC7540 Operator Management**:

- `setOperator(operator, approved)`: Approve/revoke operator
- `isOperator(controller, operator)`: Check operator status

**ERC7540 Request Functions**:

- `requestDeposit(assets, controller, owner)`: Create deposit request
  - Transfers assets to vault and tracks by epoch
  - Records net assets after entry cost deduction
  - Returns `requestId` = current epoch number
- `requestRedeem(shares, controller, owner)`: Create redeem request
  - Burns shares immediately and tracks by epoch
  - Requires ERC-20 approval or operator approval
  - Returns `requestId` = current epoch number

**ERC7540 Claim Functions (3-parameter)**:

- `deposit(assets, receiver, controller)`: Claim deposit request
  - Mints shares for settled assets
  - Processes oldest epochs first (FIFO)
  - Converts using epoch-specific share price
- `mint(shares, receiver, controller)`: Claim deposit by shares
  - Claims desired share amount
  - FIFO processing
- `withdraw(assets, receiver, controller)`: Claim withdrawal by assets
  - Withdraws desired asset amount
  - Deducts exit cost and performance fees
  - FIFO processing
- `redeem(shares, receiver, controller)`: Claim withdrawal by shares
  - Withdraws assets for claimable redeem shares
  - Deducts exit cost and performance fees
  - FIFO processing

**Note**:

- Only requests within the last 50 epochs are processed.
- All claim functions can only be called by the controller or approved operator.
- 2-parameter versions (`deposit(assets, receiver)`, `mint(shares, receiver)`) are deprecated and revert.

### 4. SettlementFacet

**Role**: Epoch settlement and auto-processing

**Key Functions**:

- `onRoundSettled(epoch)`: Called by keeper after BaseVol round settlement
  - Calculates and records current share price
  - Calculates liquidity needed for redemptions
  - Requests liquidity from Strategy (if needed)
  - Auto-processes all user requests
  - Mints management fee shares
  - Signals Strategy for liquidity rebalancing

**Settlement Process**:

1. Calculate share price (`totalAssets / effectiveTotalSupply`)
2. Record epoch data (`isSettled = true`)
3. Check required liquidity and request from Strategy
4. Auto-process deposits (mint shares)
5. Auto-process redemptions (transfer assets, deduct fees)
6. Mint management fee shares
7. Emit Strategy rebalancing event

**Restriction**: Only callable by keepers

### 5. GenesisVaultAdminFacet

**Role**: Admin functions and fee configuration

**Owner-only Functions**:

- `setBaseVolContract(address)`: Set BaseVol contract
- `setStrategy(address)`: Set Strategy contract (stops previous strategy)
- `setAdmin(address)`: Set admin address
- `shutdown()`: Shutdown vault (disable deposits, allow withdrawals only)
- `sweep(receiver)`: Recover remaining assets after all shares redeemed

**Admin-only Functions**:

- `pause(stopStrategy)`: Pause vault (disable all operations)
- `unpause()`: Unpause vault
- `setFeeInfos(recipient, managementFee, performanceFee, hurdleRate)`: Configure fees
  - `managementFee`: Max 5% (0.05e18)
  - `performanceFee`: Max 50% (0.5e18)
- `setEntryAndExitCost(entryCost, exitCost)`: Set entry/exit costs (fixed amounts)
  - Max 1,000 USDC (1000e6)
- `setDepositLimits(userLimit, vaultLimit)`: Set deposit limits

### 6. KeeperFacet

**Role**: Keeper management

**Key Functions**:

- `addKeeper(keeper)`: Add keeper (Admin-only)
- `removeKeeper(keeper)`: Remove keeper (Admin-only)
- `getKeepers()`: Get all keepers
- `isKeeper(account)`: Check if address is keeper

**Keeper Responsibilities**:

- Call `onRoundSettled()` after BaseVol round settlement
- Trigger settlement process and auto-processing

### 7. GenesisVaultInitializationFacet

**Role**: Vault initialization (called once during deployment)

**Key Functions**:

- `initialize(...)`: Initialize vault settings
  - Set asset, name, symbol, admin
  - Set BaseVol and Strategy addresses
  - Configure fee structure and limits
  - Start management fee timer
- `addInitialKeepers(keepers)`: Add initial keepers (Owner-only)

## Usage

### User Flow

#### Deposit Flow (ERC7540 Async)

```solidity
// 1. Request deposit (transfer assets and start tracking)
uint256 requestId = vault.requestDeposit(1000e6, alice, alice);
// requestId = current epoch number (e.g., 42)

// 2. Wait for settlement (keeper calls onRoundSettled)
// - Automatically processed when BaseVol round ends
// - Shares are minted and transferred to alice

// Or manually claim:
// 3a. Claim by assets
uint256 shares = vault.deposit(1000e6, alice, alice);

// 3b. Claim by shares
uint256 assets = vault.mint(sharesAmount, alice, alice);
```

#### Withdrawal Flow (ERC7540 Async)

```solidity
// 1. Request redeem (burn shares immediately and start tracking)
uint256 requestId = vault.requestRedeem(shares, alice, alice);
// requestId = current epoch number

// 2. Wait for settlement (keeper calls onRoundSettled)
// - Automatically processed when BaseVol round ends
// - Assets are transferred to alice (after fees)

// Or manually claim:
// 3a. Claim by assets
uint256 sharesUsed = vault.withdraw(1000e6, alice, alice);

// 3b. Claim by shares
uint256 assetsReceived = vault.redeem(shares, alice, alice);
```

#### Using Operators

```solidity
// 1. Alice approves Bob as operator
vault.setOperator(bob, true);

// 2. Bob requests deposit on behalf of Alice
vault.requestDeposit(1000e6, alice, alice); // Bob calls, uses Alice's assets

// 3. Bob claims on behalf of Alice
vault.deposit(1000e6, alice, alice); // Bob calls, claims Alice's request
```

### Developer Flow

#### Adding a New Facet

1. Create new facet contract in `facets/` folder
2. Import and use `LibGenesisVaultStorage`
3. Implement functions
4. Update deployment script
5. Add facet via `diamondCut`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibGenesisVaultStorage } from "../libraries/LibGenesisVaultStorage.sol";

contract MyNewFacet {
    function myFunction() external {
        LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
        // Implementation
    }
}
```

#### Modifying Storage (Use Extreme Caution!)

```solidity
struct Layout {
    // Existing variables (NEVER modify!)
    IERC20 asset;
    string name;
    // ...

    /* IMPORTANT: Add new variables here to maintain storage layout */
    uint256 newVariable;  // ✅ Safe: appended at end
    mapping(address => uint256) newMapping;  // ✅ Safe: appended at end
}
```

**NEVER**:

- ❌ Change order of existing variables
- ❌ Change types of existing variables
- ❌ Remove existing variables
- ❌ Insert new variables between existing ones

## Deployment

### Prerequisites

1. Deploy all facets
2. Deploy Diamond contract
3. Add facets via DiamondCut
4. Initialize vault

### Initial Deployment

Use the automated deployment script to deploy a new Genesis Vault Diamond.

```bash
# Compile contracts
npx hardhat compile

# Deploy to testnet (Base Sepolia)
npx hardhat run --network base_sepolia scripts/genesis-vault/deploy-genesis-vault-diamond.ts

# Deploy to mainnet (Base)
npx hardhat run --network base scripts/genesis-vault/deploy-genesis-vault-diamond.ts
```

#### Deployment Sequence

The script automatically performs the following steps:

1. **Deploy Facets** (sequential to avoid nonce issues):
   - DiamondCutFacet
   - DiamondLoupeFacet
   - ERC20Facet
   - GenesisVaultViewFacet
   - GenesisVaultAdminFacet
   - KeeperFacet
   - VaultCoreFacet
   - SettlementFacet
   - GenesisVaultInitializationFacet

2. **Verify Contract Code**: Wait for network propagation

3. **Deploy Diamond**: Deploy Diamond.sol with DiamondCutFacet

4. **Execute DiamondCut**: Add all facets with their function selectors
   - Automatically extracts selectors from each facet
   - Excludes `init()` and `initialize()` functions
   - Removes duplicate `supportsInterface()` from GenesisVaultViewFacet

5. **Initialize Vault**: Call `initialize()` with configuration
   - Asset (USDC), name, symbol, admin
   - BaseVol contract and Strategy addresses
   - Fee structure (management, performance, entry/exit costs)
   - Deposit limits

6. **Verify Deployment**: Query and display vault state
   - Name, symbol, total supply
   - All facet addresses and function counts

#### Configuration

Edit the deployment script to customize settings:

```typescript
// scripts/genesis-vault/deploy-genesis-vault-diamond.ts

const CONFIG = {
  ASSET: "0x...", // USDC address
  VAULT_NAME: "BaseVol Genesis Vault",
  VAULT_SYMBOL: "bvGV",
  ADMIN: "0x...",
  BASEVOL_CONTRACT: "0x...",
  STRATEGY: "0x...",
  FEE_RECIPIENT: "0x...",

  // Fees (in 1e18 precision: 0.02 * 1e18 = 2%)
  MANAGEMENT_FEE: 20n * 10n ** 15n, // 2% = 0.02 * 1e18
  PERFORMANCE_FEE: 200n * 10n ** 15n, // 20% = 0.20 * 1e18
  HURDLE_RATE: 0n, // 0% = 0 * 1e18

  // Entry/Exit costs (in asset decimals: USDC has 6 decimals)
  ENTRY_COST: 0n, // 0 USDC = 0 * 1e6
  EXIT_COST: 0n, // 0 USDC = 0 * 1e6

  // Limits
  USER_DEPOSIT_LIMIT: 10_000_000_000n, // 10k USDC
  VAULT_DEPOSIT_LIMIT: 100_000_000_000n, // 100k USDC
};
```

### Upgrading Facets

Use the interactive upgrade script to upgrade specific facets after deployment.

```bash
# Upgrade facets on Base Sepolia
npx hardhat run --network base_sepolia scripts/genesis-vault/upgrade-genesis-vault-facet.ts

# Upgrade facets on Base Mainnet
npx hardhat run --network base scripts/genesis-vault/upgrade-genesis-vault-facet.ts
```

#### Upgrade Process

1. **Enter Diamond Address**: Provide the Genesis Vault Diamond address
   - Default addresses are pre-configured in the script

2. **Select Facets**: Choose which facets to upgrade (multi-select with Space)
   - ERC20Facet
   - GenesisVaultViewFacet
   - GenesisVaultAdminFacet
   - KeeperFacet
   - VaultCoreFacet
   - SettlementFacet
   - GenesisVaultInitializationFacet

3. **Analysis**: Script automatically analyzes changes
   - Deploys new facet versions
   - Compares function selectors with current Diamond
   - Identifies new, existing, and removed functions
   - Generates required FacetCut operations

4. **Review Summary**: View detailed analysis

   ```
   📋 UPGRADE ANALYSIS SUMMARY
   1. VaultCoreFacet:
      🆕 Adding 2 new function(s)
      🔄 Updating 12 existing function(s)
   2. GenesisVaultAdminFacet:
      🔄 Updating 10 existing function(s)

   📊 Total Changes:
      🆕 New functions: 2
      🔄 Updated functions: 22
      ⚡ Total cut operations: 3
   ```

5. **Confirm Execution**: Type `yes` to proceed with Diamond cut

6. **Verification**: Script verifies the upgrade
   - Checks all selectors point to new facet addresses
   - Tests function accessibility
   - Optionally verifies contracts on Basescan

#### Upgrade Features

- **Smart Analysis**: Automatically detects ADD vs REPLACE operations
- **Sequential Deployment**: Avoids nonce collision issues
- **Network Stability**: Waits for contract code propagation
- **Comprehensive Verification**: Post-upgrade checks ensure correctness
- **Block Explorer Integration**: Auto-verifies on Basescan (if API key set)

#### Setting Default Addresses

Update default Diamond addresses in the upgrade script:

```typescript
// scripts/genesis-vault/upgrade-genesis-vault-facet.ts

const GENESIS_VAULT_ADDRESSES = {
  base_sepolia: "0xbc4cdBb474597d26F997A55025F78d3aB8e258EA",
  base: "0x...", // Update after mainnet deployment
};
```

### Deployment Best Practices

1. **Test on Sepolia First**: Always deploy to Base Sepolia before mainnet
2. **Verify All Addresses**: Double-check all configuration addresses
3. **Monitor Gas Costs**: Sequential deployment increases deployment time
4. **Wait for Propagation**: Script includes delays for network stability
5. **Verify on Explorer**: Use Basescan verification for transparency
6. **Document Addresses**: Save all deployed facet and Diamond addresses
7. **Backup Configuration**: Keep deployment configuration for future reference

### Troubleshooting Deployment

| Error                              | Cause                       | Solution                                    |
| ---------------------------------- | --------------------------- | ------------------------------------------- |
| "HH701: Multiple artifacts"        | Duplicate contract names    | Uses Fully Qualified Names (FQN)            |
| "No selectors in facet"            | Interface extraction failed | Check factory.interface is used             |
| "Can't add function that exists"   | Duplicate selectors         | Remove duplicate from GenesisVaultViewFacet |
| "Function does not exist"          | Network propagation delay   | Wait for contract code (built-in retry)     |
| Nonce collision                    | Parallel deployment         | Deploy sequentially (default)               |
| "Diamond: Function does not exist" | DiamondCut not applied      | Check transaction receipt and retry         |

## Security

### Access Control

| Role                      | Permissions                                                                                                                               |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| **Owner** (Diamond owner) | - Upgrade Diamond<br>- Set Strategy<br>- Set BaseVol address<br>- Set Admin<br>- Shutdown vault<br>- Recover assets (when vault is empty) |
| **Admin**                 | - Pause/unpause vault<br>- Configure fees<br>- Set deposit limits<br>- Manage keepers                                                     |
| **Keeper**                | - Settle epochs (`onRoundSettled`)                                                                                                        |
| **User**                  | - Request/claim deposits/withdrawals<br>- Set operators                                                                                   |

### Security Features

1. **Pause Mechanism**: Stop all operations in emergencies
2. **Permanent Shutdown**: Block deposits, allow withdrawals only
3. **Fee Limits**:
   - Management fee ≤ 5%
   - Performance fee ≤ 50%
   - Entry/exit costs ≤ 1,000 USDC
4. **Deposit Limits**: Per-user and vault-wide limits
5. **Storage Protection**: Diamond Storage Pattern prevents collisions

### Known Constraints

1. **Epoch Limit**: Only last 50 epochs processed (older requests expire automatically)
2. **Auto-processing**: All users auto-processed during settlement (may increase gas costs)
3. **FIFO Order**: Claims always process oldest epochs first
4. **BaseVol Dependency**: Vault cannot operate without BaseVol contract set

## Integration

### BaseVol Integration

GenesisVault integrates tightly with BaseVol for epoch-based settlement.

```solidity
// 1. Set BaseVol address
vault.setBaseVolContract(baseVolAddress);

// 2. Add keeper
vault.addKeeper(keeperAddress);

// 3. Keeper calls after BaseVol round ends
vault.onRoundSettled(epoch);
```

**Integration Points**:

- `getCurrentEpoch()`: Queries BaseVol's `currentEpoch()` in real-time
- `onRoundSettled(epoch)`: Called at end of each round to perform settlement

### Strategy Integration

The vault delegates asset management to GenesisStrategy.

```solidity
// 1. Deploy GenesisStrategy (initialized with vault address)
// 2. Set strategy
vault.setStrategy(strategyAddress);

// Strategy interactions:
// - Strategy pulls assets via allocateAssets()
// - Vault requests liquidity via provideLiquidityForWithdrawals(amount)
```

**Strategy Interface**:

- `totalAssetsUnderManagement()`: Total assets managed by Strategy
- `utilizedAssets()`: Assets currently utilized by Strategy
- `provideLiquidityForWithdrawals(amount)`: Provide specific liquidity amount
- `processAssetsToWithdraw()`: Process withdrawable assets (fallback method)
- `pause()`, `unpause()`, `stop()`: Strategy state management

### ERC7540 Operator System

Operators can manage deposits/withdrawals on behalf of users.

```solidity
// Approve operator
vault.setOperator(operator, true);

// Operator makes requests
vault.requestDeposit(assets, controller, owner);
vault.requestRedeem(shares, controller, owner);

// Operator claims
vault.deposit(assets, receiver, controller);
vault.redeem(shares, receiver, controller);
```

**Note**:

- Redeem requests work with either ERC-20 approval OR operator approval
- Operators don't consume allowance

## Gas Considerations

- **Diamond Overhead**: ~2.5k gas delegatecall overhead per function call
- **Auto-processing**: Gas scales with number of users during settlement
- **FIFO Processing**: Multiple epochs increase gas due to loops
- **50 Epoch Limit**: Loop limit prevents excessive gas consumption

## Key Events

### Deposit/Withdrawal Events

- `DepositRequest(controller, owner, requestId, sender, assets)`
- `RedeemRequest(controller, owner, requestId, sender, shares)`
- `Deposit(sender, owner, assets, shares)`
- `Withdraw(sender, receiver, owner, assets, shares)`

### Settlement Events

- `RoundSettled(epoch, sharePrice)`
- `RoundSettlementProcessed(epoch, requiredRedeemAssets, availableAssets, liquidityRequestMade)`
- `StrategyLiquidityRequested(amount)`
- `StrategyUtilizationNotified(idleAssets)`

### Admin Events

- `BaseVolContractSet(baseVolContract)`
- `StrategyUpdated(oldStrategy, newStrategy)`
- `Paused(account)`, `Unpaused(account)`, `Shutdown(account)`
- `ManagementFeeChanged(account, newManagementFee)`
- `PerformanceFeeChanged(account, newPerformanceFee)`
- `PerformanceFeeCharged(user, feeAmount, currentSharePrice, userWAEP)`

### Operator Events

- `OperatorSet(controller, operator, approved)`

### Keeper Events

- `KeeperAdded(keeper)`
- `KeeperRemoved(keeper)`

## Debug Commands

```solidity
// List all facets
vault.facets();

// Get function selectors for a facet
vault.facetFunctionSelectors(facetAddress);

// Check epoch settlement status
vault.roundData(epoch);

// Check claimable amounts
vault.claimableDepositRequest(requestId, controller);
vault.claimableRedeemRequest(requestId, controller);

// Check pending requests
vault.pendingDepositRequest(requestId, controller);
vault.pendingRedeemRequest(requestId, controller);

// Get user epoch lists
vault.getUserDepositEpochs(user);
vault.getUserRedeemEpochs(user);

// Get epoch user lists
vault.getEpochDepositUsers(epoch);
vault.getEpochRedeemUsers(epoch);
```

## Contract Statistics

| Metric              | Value                                |
| ------------------- | ------------------------------------ |
| Number of Facets    | 7                                    |
| Total Functions     | ~90                                  |
| Storage Variables   | ~30                                  |
| Events              | ~20                                  |
| Standards Supported | ERC-20, ERC-4626, ERC-7540, EIP-2535 |
| Max Facet Size      | <822 lines (<24KB)                   |

## Documentation

- **Diamond Common**: `../diamond-common/` - Diamond base components
- **Implementation Guide**: `../../docs/GENESIS_VAULT_DIAMOND_IMPLEMENTATION.md`
- **Diamond Pattern Proposal**: `../../docs/diamond-pattern-proposal.md`

## External References

- [EIP-2535: Diamond Standard](https://eips.ethereum.org/EIPS/eip-2535)
- [ERC-7540: Asynchronous Vaults](https://eips.ethereum.org/EIPS/eip-7540)
- [ERC-4626: Tokenized Vaults](https://eips.ethereum.org/EIPS/eip-4626)
- [Diamond Pattern Tutorial](https://eip2535diamonds.substack.com/)

## Troubleshooting

| Error                            | Cause                        | Solution                                  |
| -------------------------------- | ---------------------------- | ----------------------------------------- |
| "Function does not exist"        | Facet not added              | Add facet via diamondCut                  |
| "Only keeper"                    | Unauthorized caller          | Add address to keeper list                |
| "Insufficient claimable"         | Request not settled          | Wait for onRoundSettled call              |
| "BaseVolContractNotSet"          | BaseVol not set              | Call setBaseVolContract                   |
| Storage collision                | Storage modified incorrectly | Only append to storage                    |
| "VaultCoreFacet: Not authorized" | Not controller or operator   | Call with correct address or set operator |

---

**Version**: 1.0.0  
**Last Updated**: 2025-10-02  
**Status**: ✅ Production Ready  
**Network**: Base Sepolia, Base Mainnet
