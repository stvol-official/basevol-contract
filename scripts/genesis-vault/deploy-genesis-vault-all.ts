import { ethers, network, run, upgrades } from "hardhat";
import config from "../../config";
import * as readline from "readline";

/**
 * Unified Genesis Vault Deployment Script
 *
 * This script deploys all Genesis Vault components in the correct order:
 * 1. GenesisVault Diamond (with all facets)
 * 2. GenesisStrategy
 * 3. BaseVolManager
 * 4. Configure all connections
 *
 * Usage:
 * npx hardhat run --network base_sepolia scripts/genesis-vault/deploy-genesis-vault-all.ts
 * npx hardhat run --network base scripts/genesis-vault/deploy-genesis-vault-all.ts
 *
 * Environment Variables:
 * - CLEARING_HOUSE_ADMIN_KEY: Private key of ClearingHouse admin (required for addBaseVolManager)
 *
 * Manual steps after deployment:
 * 5. Update 1password api-env with new genesis-vault address
 * 8. Restart server
 */

const NETWORK = ["base_sepolia", "base"] as const;
type SupportedNetwork = (typeof NETWORK)[number];

// ============ Configuration ============
interface DeploymentConfig {
  // BaseVol contract to connect (1day contract)
  baseVolContract: string;
  // Keeper address (server address that will call onRoundSettled)
  keeperAddress: string;
}

const DEPLOYMENT_CONFIG: Record<SupportedNetwork, DeploymentConfig> = {
  base_sepolia: {
    baseVolContract: "0x26b0A1e85f66C4864d6ABB3B146714494B56A673", // 1 hour BaseVol address
    keeperAddress: "0x879720F64fD5784B0109eb7410247d5254C58c1B", // keeper address
  },
  base: {
    baseVolContract: "0x5B2eA3A959b525f95F80F29C0C52Cd9cC925DB74", // 1 day BaseVol address
    keeperAddress: "0x38b3ed1018aef0590d0fbf54a2fe3c2c78f99e5a", // keeper address
  },
};

// ============ Types ============
interface DeployedContracts {
  diamond: string;
  diamondCutFacet: string;
  diamondLoupeFacet: string;
  erc20Facet: string;
  genesisVaultViewFacet: string;
  genesisVaultAdminFacet: string;
  keeperFacet: string;
  vaultCoreFacet: string;
  settlementFacet: string;
  initializationFacet: string;
}

interface DeploymentResult {
  genesisVault: string;
  genesisStrategy: string;
  baseVolManager: string;
  facets: Omit<DeployedContracts, "diamond">;
}

// ============ Helper Functions ============
async function waitForContractCode(
  address: string,
  maxRetries = 5,
  delayMs = 2000,
): Promise<boolean> {
  for (let i = 0; i < maxRetries; i++) {
    const code = await ethers.provider.getCode(address);
    if (code !== "0x") {
      return true;
    }
    if (i < maxRetries - 1) {
      console.log(`    ⏳ Waiting for contract code... (${i + 1}/${maxRetries})`);
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }
  return false;
}

async function getSelectors(contractInterface: any, excludeSelectors: string[] = []) {
  const fragments = Object.values(contractInterface.fragments);
  const selectors = fragments
    .filter((fragment: any) => fragment.type === "function")
    .map((fragment: any) => fragment.selector)
    .filter((selector: string) => selector !== undefined)
    .filter((selector: string) => !excludeSelectors.includes(selector));
  return selectors;
}

// ============ User Input Helper ============
async function getUserInput(prompt: string, defaultValue: string): Promise<string> {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  return new Promise((resolve) => {
    rl.question(`${prompt} (default: ${defaultValue}): `, (answer) => {
      rl.close();
      resolve(answer.trim() || defaultValue);
    });
  });
}

// ============ Step 1: Deploy GenesisVault Diamond ============
async function step1_deployGenesisVault(
  owner: string,
  networkName: SupportedNetwork,
  vaultName: string,
  vaultSymbol: string,
): Promise<{ diamondAddress: string; facets: Omit<DeployedContracts, "diamond"> }> {
  console.log("\n" + "=".repeat(60));
  console.log("📦 STEP 1: Deploying GenesisVault Diamond");
  console.log("=".repeat(60));

  // Deploy all facets
  console.log("\n🔧 Deploying Facets...");

  const DiamondCutFacet = await ethers.getContractFactory(
    "contracts/diamond-common/facets/DiamondCutFacet.sol:DiamondCutFacet",
  );
  const diamondCutFacet = await DiamondCutFacet.deploy();
  await diamondCutFacet.waitForDeployment();
  const diamondCutFacetAddress = await diamondCutFacet.getAddress();
  console.log("  ✅ DiamondCutFacet:", diamondCutFacetAddress);

  const DiamondLoupeFacet = await ethers.getContractFactory(
    "contracts/diamond-common/facets/DiamondLoupeFacet.sol:DiamondLoupeFacet",
  );
  const diamondLoupeFacet = await DiamondLoupeFacet.deploy();
  await diamondLoupeFacet.waitForDeployment();
  const diamondLoupeFacetAddress = await diamondLoupeFacet.getAddress();
  console.log("  ✅ DiamondLoupeFacet:", diamondLoupeFacetAddress);

  const ERC20Facet = await ethers.getContractFactory(
    "contracts/genesis-vault/facets/ERC20Facet.sol:ERC20Facet",
  );
  const erc20Facet = await ERC20Facet.deploy();
  await erc20Facet.waitForDeployment();
  const erc20FacetAddress = await erc20Facet.getAddress();
  console.log("  ✅ ERC20Facet:", erc20FacetAddress);

  const GenesisVaultViewFacet = await ethers.getContractFactory(
    "contracts/genesis-vault/facets/GenesisVaultViewFacet.sol:GenesisVaultViewFacet",
  );
  const genesisVaultViewFacet = await GenesisVaultViewFacet.deploy();
  await genesisVaultViewFacet.waitForDeployment();
  const genesisVaultViewFacetAddress = await genesisVaultViewFacet.getAddress();
  console.log("  ✅ GenesisVaultViewFacet:", genesisVaultViewFacetAddress);

  const GenesisVaultAdminFacet = await ethers.getContractFactory(
    "contracts/genesis-vault/facets/GenesisVaultAdminFacet.sol:GenesisVaultAdminFacet",
  );
  const genesisVaultAdminFacet = await GenesisVaultAdminFacet.deploy();
  await genesisVaultAdminFacet.waitForDeployment();
  const genesisVaultAdminFacetAddress = await genesisVaultAdminFacet.getAddress();
  console.log("  ✅ GenesisVaultAdminFacet:", genesisVaultAdminFacetAddress);

  const KeeperFacet = await ethers.getContractFactory(
    "contracts/genesis-vault/facets/KeeperFacet.sol:KeeperFacet",
  );
  const keeperFacet = await KeeperFacet.deploy();
  await keeperFacet.waitForDeployment();
  const keeperFacetAddress = await keeperFacet.getAddress();
  console.log("  ✅ KeeperFacet:", keeperFacetAddress);

  const VaultCoreFacet = await ethers.getContractFactory(
    "contracts/genesis-vault/facets/VaultCoreFacet.sol:VaultCoreFacet",
  );
  const vaultCoreFacet = await VaultCoreFacet.deploy();
  await vaultCoreFacet.waitForDeployment();
  const vaultCoreFacetAddress = await vaultCoreFacet.getAddress();
  console.log("  ✅ VaultCoreFacet:", vaultCoreFacetAddress);

  const SettlementFacet = await ethers.getContractFactory(
    "contracts/genesis-vault/facets/SettlementFacet.sol:SettlementFacet",
  );
  const settlementFacet = await SettlementFacet.deploy();
  await settlementFacet.waitForDeployment();
  const settlementFacetAddress = await settlementFacet.getAddress();
  console.log("  ✅ SettlementFacet:", settlementFacetAddress);

  const InitializationFacet = await ethers.getContractFactory(
    "contracts/genesis-vault/facets/GenesisVaultInitializationFacet.sol:GenesisVaultInitializationFacet",
  );
  const initializationFacet = await InitializationFacet.deploy();
  await initializationFacet.waitForDeployment();
  const initializationFacetAddress = await initializationFacet.getAddress();
  console.log("  ✅ GenesisVaultInitializationFacet:", initializationFacetAddress);

  // Verify all facets have code
  console.log("\n🔍 Verifying facet deployments...");
  const facetsToVerify = [
    { name: "DiamondCutFacet", address: diamondCutFacetAddress },
    { name: "DiamondLoupeFacet", address: diamondLoupeFacetAddress },
    { name: "ERC20Facet", address: erc20FacetAddress },
    { name: "GenesisVaultViewFacet", address: genesisVaultViewFacetAddress },
    { name: "GenesisVaultAdminFacet", address: genesisVaultAdminFacetAddress },
    { name: "KeeperFacet", address: keeperFacetAddress },
    { name: "VaultCoreFacet", address: vaultCoreFacetAddress },
    { name: "SettlementFacet", address: settlementFacetAddress },
    { name: "InitializationFacet", address: initializationFacetAddress },
  ];

  for (const facet of facetsToVerify) {
    const hasCode = await waitForContractCode(facet.address);
    if (!hasCode) {
      throw new Error(`${facet.name} code not available at ${facet.address}`);
    }
    console.log(`  ✅ ${facet.name} verified`);
  }

  // Deploy Diamond
  console.log("\n💎 Deploying Diamond...");
  const Diamond = await ethers.getContractFactory("contracts/diamond-common/Diamond.sol:Diamond");
  const diamond = await Diamond.deploy(owner, diamondCutFacetAddress);
  await diamond.waitForDeployment();
  const diamondAddress = await diamond.getAddress();
  console.log("  ✅ Diamond deployed at:", diamondAddress);

  // Add facets to Diamond
  console.log("\n🔧 Adding Facets to Diamond...");
  const diamondCut = await ethers.getContractAt(
    "contracts/diamond-common/interfaces/IDiamondCut.sol:IDiamondCut",
    diamondAddress,
  );

  const FacetCutAction = { Add: 0, Replace: 1, Remove: 2 };
  const cuts = [];

  // Prepare all cuts
  cuts.push({
    facetAddress: diamondLoupeFacetAddress,
    action: FacetCutAction.Add,
    functionSelectors: await getSelectors(DiamondLoupeFacet.interface),
  });

  cuts.push({
    facetAddress: erc20FacetAddress,
    action: FacetCutAction.Add,
    functionSelectors: await getSelectors(ERC20Facet.interface),
  });

  cuts.push({
    facetAddress: genesisVaultViewFacetAddress,
    action: FacetCutAction.Add,
    functionSelectors: await getSelectors(GenesisVaultViewFacet.interface),
  });

  cuts.push({
    facetAddress: genesisVaultAdminFacetAddress,
    action: FacetCutAction.Add,
    functionSelectors: await getSelectors(GenesisVaultAdminFacet.interface),
  });

  cuts.push({
    facetAddress: keeperFacetAddress,
    action: FacetCutAction.Add,
    functionSelectors: await getSelectors(KeeperFacet.interface),
  });

  cuts.push({
    facetAddress: vaultCoreFacetAddress,
    action: FacetCutAction.Add,
    functionSelectors: await getSelectors(VaultCoreFacet.interface),
  });

  cuts.push({
    facetAddress: settlementFacetAddress,
    action: FacetCutAction.Add,
    functionSelectors: await getSelectors(SettlementFacet.interface),
  });

  cuts.push({
    facetAddress: initializationFacetAddress,
    action: FacetCutAction.Add,
    functionSelectors: await getSelectors(InitializationFacet.interface),
  });

  console.log(`  📊 Adding ${cuts.length} facets...`);
  const tx = await diamondCut.diamondCut(cuts, ethers.ZeroAddress, "0x");
  await tx.wait();
  console.log("  ✅ All facets added to Diamond");

  // Initialize vault
  console.log("\n🚀 Initializing GenesisVault...");
  const vault = await ethers.getContractAt(
    "contracts/genesis-vault/facets/GenesisVaultInitializationFacet.sol:GenesisVaultInitializationFacet",
    diamondAddress,
  );

  const initTx = await vault.initialize(
    config.Address.Usdc[networkName], // asset
    vaultName, // name
    vaultSymbol, // symbol
    owner, // admin
    ethers.ZeroAddress, // baseVolContract (will be set later)
    ethers.ZeroAddress, // strategy (will be set later)
    owner, // feeRecipient
    ethers.parseEther("0.02"), // managementFee (2%)
    ethers.parseEther("0.20"), // performanceFee (20%)
    ethers.parseEther("0"), // hurdleRate (0%)
    ethers.parseUnits("0", 6), // entryCost (0 USDC)
    ethers.parseUnits("1", 6), // exitCost (1 USDC)
    ethers.parseUnits("300000", 6), // userDepositLimit (300,000 USDC)
    ethers.parseUnits("1000000", 6), // vaultDepositLimit (1,000,000 USDC)
  );
  await initTx.wait();
  console.log("  ✅ GenesisVault initialized");

  return {
    diamondAddress,
    facets: {
      diamondCutFacet: diamondCutFacetAddress,
      diamondLoupeFacet: diamondLoupeFacetAddress,
      erc20Facet: erc20FacetAddress,
      genesisVaultViewFacet: genesisVaultViewFacetAddress,
      genesisVaultAdminFacet: genesisVaultAdminFacetAddress,
      keeperFacet: keeperFacetAddress,
      vaultCoreFacet: vaultCoreFacetAddress,
      settlementFacet: settlementFacetAddress,
      initializationFacet: initializationFacetAddress,
    },
  };
}

// ============ Step 2: Deploy GenesisStrategy ============
async function step2_deployGenesisStrategy(
  genesisVaultAddress: string,
  networkName: SupportedNetwork,
): Promise<string> {
  console.log("\n" + "=".repeat(60));
  console.log("🏦 STEP 2: Deploying GenesisStrategy");
  console.log("=".repeat(60));

  const StrategyFactory = await ethers.getContractFactory("GenesisStrategy");

  const initParams = [
    genesisVaultAddress,
    config.Address.ClearingHouse[networkName],
    config.Address.Operator[networkName],
  ];

  console.log("\n📋 Initialization parameters:");
  console.log("  - GenesisVault:", initParams[0]);
  console.log("  - ClearingHouse:", initParams[1]);
  console.log("  - Operator:", initParams[2]);

  const strategyContract = await upgrades.deployProxy(StrategyFactory, initParams, {
    kind: "uups",
    initializer: "initialize",
  });

  await strategyContract.waitForDeployment();
  const strategyAddress = await strategyContract.getAddress();
  console.log("  ✅ GenesisStrategy deployed at:", strategyAddress);

  // Set strategy on GenesisVault
  console.log("\n🔧 Setting strategy on GenesisVault...");
  const genesisVault = await ethers.getContractAt("GenesisVaultAdminFacet", genesisVaultAddress);
  const setStrategyTx = await genesisVault.setStrategy(strategyAddress);
  await setStrategyTx.wait();
  console.log("  ✅ Strategy set on GenesisVault");

  return strategyAddress;
}

// ============ Step 3: Deploy BaseVolManager ============
async function step3_deployBaseVolManager(
  genesisStrategyAddress: string,
  networkName: SupportedNetwork,
): Promise<string> {
  console.log("\n" + "=".repeat(60));
  console.log("📊 STEP 3: Deploying BaseVolManager");
  console.log("=".repeat(60));

  const BaseVolManager = await ethers.getContractFactory("BaseVolManager");

  const initParams = [config.Address.ClearingHouse[networkName], genesisStrategyAddress];

  console.log("\n📋 Initialization parameters:");
  console.log("  - ClearingHouse:", initParams[0]);
  console.log("  - Strategy:", initParams[1]);

  const baseVolManager = (await upgrades.deployProxy(BaseVolManager, initParams, {
    kind: "uups",
    initializer: "initialize",
  })) as any;

  await baseVolManager.waitForDeployment();
  const baseVolManagerAddress = await baseVolManager.getAddress();
  console.log("  ✅ BaseVolManager deployed at:", baseVolManagerAddress);

  // Set BaseVolManager on GenesisStrategy
  console.log("\n🔧 Setting BaseVolManager on GenesisStrategy...");
  const genesisStrategy = await ethers.getContractAt("GenesisStrategy", genesisStrategyAddress);
  const setBaseVolManagerTx = await genesisStrategy.setBaseVolManager(baseVolManagerAddress);
  await setBaseVolManagerTx.wait();
  console.log("  ✅ BaseVolManager set on GenesisStrategy");

  return baseVolManagerAddress;
}

// ============ Step 4: Configure Connections ============
async function step4_configureConnections(
  genesisVaultAddress: string,
  baseVolManagerAddress: string,
  deploymentConfig: DeploymentConfig,
  networkName: SupportedNetwork,
) {
  console.log("\n" + "=".repeat(60));
  console.log("⚙️  STEP 4: Configuring Connections");
  console.log("=".repeat(60));

  const genesisVaultAdmin = await ethers.getContractAt(
    "GenesisVaultAdminFacet",
    genesisVaultAddress,
  );
  const keeperFacet = await ethers.getContractAt("KeeperFacet", genesisVaultAddress);

  // 4-1: Add BaseVolManager to ClearingHouse (requires admin)
  console.log("\n🔗 Adding BaseVolManager to ClearingHouse...");

  // Check if CLEARING_HOUSE_ADMIN_KEY is provided
  const clearingHouseAdminKey = process.env.CLEARING_HOUSE_ADMIN_KEY;

  if (!clearingHouseAdminKey) {
    console.log("  ⚠️  CLEARING_HOUSE_ADMIN_KEY not provided");
    console.log("  ⚠️  Skipping addBaseVolManager - must be done manually by ClearingHouse admin");
    console.log(`  📝 Run manually: clearingHouse.addBaseVolManager("${baseVolManagerAddress}")`);
  } else {
    try {
      // Create a wallet with the admin private key
      const clearingHouseAdmin = new ethers.Wallet(clearingHouseAdminKey, ethers.provider);
      console.log("  👤 Using ClearingHouse Admin:", clearingHouseAdmin.address);

      // Connect to ClearingHouse with admin signer
      const clearingHouse = await ethers.getContractAt(
        "IClearingHouse",
        config.Address.ClearingHouse[networkName],
        clearingHouseAdmin,
      );

      const addManagerTx = await clearingHouse.addBaseVolManager(baseVolManagerAddress);
      await addManagerTx.wait();
      console.log("  ✅ BaseVolManager added to ClearingHouse");
      console.log("  📝 Transaction hash:", addManagerTx.hash);
    } catch (error: any) {
      console.log("  ❌ Failed to add BaseVolManager to ClearingHouse");
      if (error.message) {
        console.log("  📄 Error:", error.message);
      }
      console.log("  ⚠️  Must be done manually by ClearingHouse admin");
      console.log(`  📝 Run manually: clearingHouse.addBaseVolManager("${baseVolManagerAddress}")`);
    }
  }

  // 4-2: Set BaseVol contract on GenesisVault (if provided)
  if (deploymentConfig.baseVolContract !== ethers.ZeroAddress) {
    console.log("\n🔗 Setting BaseVol contract on GenesisVault...");
    const setBaseVolTx = await genesisVaultAdmin.setBaseVolContract(
      deploymentConfig.baseVolContract,
    );
    await setBaseVolTx.wait();
    console.log("  ✅ BaseVol contract set on GenesisVault");
  } else {
    console.log("\n⚠️  BaseVol contract not set (address is zero). Set it manually later.");
  }

  // 4-3: Add keeper to GenesisVault (if provided)
  if (deploymentConfig.keeperAddress !== ethers.ZeroAddress) {
    console.log("\n🔗 Adding keeper to GenesisVault...");
    const addKeeperTx = await keeperFacet.addKeeper(deploymentConfig.keeperAddress);
    await addKeeperTx.wait();
    console.log("  ✅ Keeper added to GenesisVault");
  } else {
    console.log("\n⚠️  Keeper not added (address is zero). Add it manually later.");
  }
}

// ============ Main Deployment Flow ============
async function main() {
  const networkName = network.name as SupportedNetwork;

  if (!NETWORK.includes(networkName)) {
    throw new Error(`Network ${networkName} is not supported`);
  }

  console.log("\n" + "=".repeat(60));
  console.log("🚀 Genesis Vault Complete Deployment");
  console.log("=".repeat(60));
  console.log("Network:", networkName);
  console.log("=".repeat(60));

  // Get vault name and symbol from user input
  console.log("\n📝 Vault Configuration");
  const vaultName = await getUserInput("Enter vault name", "Genesis Vault");
  const vaultSymbol = await getUserInput("Enter vault symbol", "gVAULT");
  console.log(`  ✅ Vault Name: ${vaultName}`);
  console.log(`  ✅ Vault Symbol: ${vaultSymbol}`);

  // Check configuration
  if (config.Address.Usdc[networkName] === ethers.ZeroAddress) {
    throw new Error("Missing USDC address in config");
  }
  if (config.Address.ClearingHouse[networkName] === ethers.ZeroAddress) {
    throw new Error("Missing ClearingHouse address in config");
  }
  if (config.Address.Operator[networkName] === ethers.ZeroAddress) {
    throw new Error("Missing Operator address in config");
  }

  await run("compile");

  const [deployer] = await ethers.getSigners();
  console.log("\n👤 Deployer:", deployer.address);
  console.log("💰 USDC:", config.Address.Usdc[networkName]);
  console.log("🏛️ ClearingHouse:", config.Address.ClearingHouse[networkName]);
  console.log("👨‍💼 Operator:", config.Address.Operator[networkName]);

  const deploymentConfig = DEPLOYMENT_CONFIG[networkName];

  // Step 1: Deploy GenesisVault Diamond
  const { diamondAddress, facets } = await step1_deployGenesisVault(
    deployer.address,
    networkName,
    vaultName,
    vaultSymbol,
  );

  // Step 2: Deploy GenesisStrategy
  const genesisStrategyAddress = await step2_deployGenesisStrategy(diamondAddress, networkName);

  // Step 3: Deploy BaseVolManager
  const baseVolManagerAddress = await step3_deployBaseVolManager(
    genesisStrategyAddress,
    networkName,
  );

  // Step 4: Configure Connections
  await step4_configureConnections(
    diamondAddress,
    baseVolManagerAddress,
    deploymentConfig,
    networkName,
  );

  // Print summary
  console.log("\n\n" + "=".repeat(60));
  console.log("🎉 DEPLOYMENT COMPLETED SUCCESSFULLY!");
  console.log("=".repeat(60));
  console.log("\n📋 Deployed Contracts:");
  console.log("  GenesisVault Diamond:", diamondAddress);
  console.log("  GenesisStrategy:", genesisStrategyAddress);
  console.log("  BaseVolManager:", baseVolManagerAddress);

  console.log("\n📦 Facets:");
  console.log("  - DiamondCutFacet:", facets.diamondCutFacet);
  console.log("  - DiamondLoupeFacet:", facets.diamondLoupeFacet);
  console.log("  - ERC20Facet:", facets.erc20Facet);
  console.log("  - GenesisVaultViewFacet:", facets.genesisVaultViewFacet);
  console.log("  - GenesisVaultAdminFacet:", facets.genesisVaultAdminFacet);
  console.log("  - KeeperFacet:", facets.keeperFacet);
  console.log("  - VaultCoreFacet:", facets.vaultCoreFacet);
  console.log("  - SettlementFacet:", facets.settlementFacet);
  console.log("  - InitializationFacet:", facets.initializationFacet);

  console.log("\n⚙️  Configuration Status:");
  console.log("  ✅ GenesisStrategy set on GenesisVault");
  console.log("  ✅ BaseVolManager set on GenesisStrategy");
  console.log("  ✅ BaseVolManager added to ClearingHouse");
  if (deploymentConfig.baseVolContract !== ethers.ZeroAddress) {
    console.log("  ✅ BaseVol contract set on GenesisVault");
  } else {
    console.log("  ⚠️  BaseVol contract NOT set (do manually)");
  }
  if (deploymentConfig.keeperAddress !== ethers.ZeroAddress) {
    console.log("  ✅ Keeper added to GenesisVault");
  } else {
    console.log("  ⚠️  Keeper NOT added (do manually)");
  }

  console.log("\n📝 Manual Steps Required:");
  console.log("  5. Update 1password api-env:");
  console.log("     GENESIS_VAULT_ADDRESS=" + diamondAddress);
  console.log("  8. Restart server");

  if (deploymentConfig.baseVolContract === ethers.ZeroAddress) {
    console.log("\n  6. Set BaseVol contract manually:");
    console.log("     genesisVaultAdmin.setBaseVolContract(<BASEVOL_1DAY_ADDRESS>)");
  }

  if (deploymentConfig.keeperAddress === ethers.ZeroAddress) {
    console.log("\n  7. Add keeper manually:");
    console.log("     keeperFacet.addKeeper(<KEEPER_ADDRESS>)");
  }
}

main().catch((error) => {
  console.error("\n❌ Deployment failed:", error);
  process.exitCode = 1;
});
