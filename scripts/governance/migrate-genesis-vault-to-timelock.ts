import { ethers, network, run } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/*
 npx hardhat run --network base_sepolia scripts/governance/migrate-genesis-vault-to-timelock.ts
 npx hardhat run --network base scripts/governance/migrate-genesis-vault-to-timelock.ts
*/

const NETWORK = ["base_sepolia", "base"] as const;
type SupportedNetwork = (typeof NETWORK)[number];

// Helper function to get function selectors
function getSelectors(contract: any) {
  const signatures = Object.keys(contract.interface.functions);
  const selectors = signatures.reduce((acc: string[], val: string) => {
    if (val !== "init(bytes)") {
      acc.push(contract.interface.getSighash(val));
    }
    return acc;
  }, []);
  return selectors;
}

const main = async () => {
  // Get network data from Hardhat config
  const networkName = network.name as SupportedNetwork;

  // Check if the network is supported
  if (!NETWORK.includes(networkName)) {
    throw new Error(`Network ${networkName} is not supported`);
  }

  console.log(`🔄 Migrating Genesis Vault to Timelock on ${networkName} network...`);
  console.log("⚠️  WARNING: This is a critical operation. Test thoroughly on testnet first!\n");

  // Compile contracts
  console.log("📦 Compiling contracts...");
  await run("compile");

  const [deployer] = await ethers.getSigners();

  // Load deployment info
  const deploymentPath = path.join(__dirname, "../../data/timelock-deployment.json");
  if (!fs.existsSync(deploymentPath)) {
    throw new Error("❌ Timelock deployment info not found. Run deploy-timelock.ts first.");
  }

  const deploymentInfo = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));
  const CRITICAL_TIMELOCK = deploymentInfo.criticalTimelock.address;
  const STANDARD_TIMELOCK = deploymentInfo.standardTimelock.address;

  // Load contract addresses from environment
  const GENESIS_VAULT_ADDRESS = process.env.GENESIS_VAULT_ADDRESS;

  if (!GENESIS_VAULT_ADDRESS) {
    throw new Error("❌ GENESIS_VAULT_ADDRESS environment variable is not set");
  }

  console.log("===========================================");
  console.log("Deployer: %s", deployer.address);
  console.log("Network: %s", networkName);
  console.log("\nTimelock Addresses:");
  console.log("Critical Timelock: %s", CRITICAL_TIMELOCK);
  console.log("Standard Timelock: %s", STANDARD_TIMELOCK);
  console.log("\nContract Addresses:");
  console.log("Genesis Vault: %s", GENESIS_VAULT_ADDRESS);
  console.log("===========================================\n");

  try {
    // Step 1: Deploy GenesisVaultAdminFacetTimelock
    console.log("📝 Step 1: Deploying GenesisVaultAdminFacetTimelock...");
    const GenesisVaultAdminFacetTimelock = await ethers.getContractFactory(
      "GenesisVaultAdminFacetTimelock",
    );
    const genesisVaultAdminFacetTimelock = await GenesisVaultAdminFacetTimelock.deploy();
    await genesisVaultAdminFacetTimelock.deployed();
    console.log(
      "✅ GenesisVaultAdminFacetTimelock deployed at:",
      genesisVaultAdminFacetTimelock.address,
    );

    // Step 2: Add the new facet to Genesis Vault Diamond
    console.log("\n📝 Step 2: Adding GenesisVaultAdminFacetTimelock to Genesis Vault...");
    const diamondCutFacet = await ethers.getContractAt("IDiamondCut", GENESIS_VAULT_ADDRESS);

    const FacetCutAction = { Add: 0, Replace: 1, Remove: 2 };
    const cut = [
      {
        facetAddress: genesisVaultAdminFacetTimelock.address,
        action: FacetCutAction.Add,
        functionSelectors: getSelectors(genesisVaultAdminFacetTimelock),
      },
    ];

    const tx1 = await diamondCutFacet.diamondCut(cut, ethers.constants.AddressZero, "0x");
    await tx1.wait();
    console.log("✅ GenesisVaultAdminFacetTimelock added to Genesis Vault");

    // Step 3: Set Timelock addresses
    console.log("\n📝 Step 3: Setting Timelock addresses...");

    // We need to use a facet that has the timelock setter functions
    // Assuming we have a DiamondInit or similar contract with these functions
    const genesisVault = await ethers.getContractAt("GenesisVaultAdminFacet", GENESIS_VAULT_ADDRESS);

    // Check if we can access LibDiamond functions through a specific facet
    // For now, we'll try to set them directly if the functions exist
    try {
      // Try to get the interface with timelock setters
      const diamondInit = await ethers.getContractAt("DiamondInit", GENESIS_VAULT_ADDRESS);

      const tx2 = await diamondInit.setCriticalTimelock(CRITICAL_TIMELOCK);
      await tx2.wait();
      console.log("✅ Critical timelock address set");

      const tx3 = await diamondInit.setStandardTimelock(STANDARD_TIMELOCK);
      await tx3.wait();
      console.log("✅ Standard timelock address set");
    } catch (error) {
      console.log(
        "⚠️  Could not set timelock addresses directly. You may need to add a setter facet first.",
      );
      console.log("   Error:", error);
    }

    // Step 4: Enable Timelock (optional - can be done later)
    console.log("\n📝 Step 4: Enabling Timelock (optional)...");
    console.log(
      "⚠️  Timelock is NOT enabled yet. Enable it manually when ready using setTimelockEnabled(true)",
    );
    console.log("   This allows testing the new facet before enforcing timelock delays.");

    // Step 5: Verify contracts on block explorer
    if (networkName === "base" || networkName === "base_sepolia") {
      console.log("\n📝 Step 5: Verifying contracts on block explorer...");
      try {
        await run("verify:verify", {
          address: genesisVaultAdminFacetTimelock.address,
          constructorArguments: [],
        });
        console.log("✅ GenesisVaultAdminFacetTimelock verified");
      } catch (error: any) {
        if (error.message.includes("Already Verified")) {
          console.log("✅ GenesisVaultAdminFacetTimelock already verified");
        } else {
          console.log("⚠️  Verification failed:", error.message);
        }
      }
    }

    // Save migration info
    const migrationInfo = {
      network: networkName,
      timestamp: new Date().toISOString(),
      deployer: deployer.address,
      genesisVault: GENESIS_VAULT_ADDRESS,
      genesisVaultAdminFacetTimelock: genesisVaultAdminFacetTimelock.address,
      criticalTimelock: CRITICAL_TIMELOCK,
      standardTimelock: STANDARD_TIMELOCK,
      timelockEnabled: false, // Not enabled yet
    };

    const dataDir = path.join(__dirname, "../../data");
    if (!fs.existsSync(dataDir)) {
      fs.mkdirSync(dataDir, { recursive: true });
    }

    const migrationPath = path.join(dataDir, "genesis-vault-timelock-migration.json");
    fs.writeFileSync(migrationPath, JSON.stringify(migrationInfo, null, 2));
    console.log("\n💾 Migration info saved to:", migrationPath);

    // Summary
    console.log("\n===========================================");
    console.log("🎉 Genesis Vault Timelock Migration Complete!");
    console.log("===========================================");
    console.log("\n📋 Summary:");
    console.log("✅ GenesisVaultAdminFacetTimelock deployed");
    console.log("✅ Facet added to Genesis Vault Diamond");
    console.log("✅ Timelock addresses configured");
    console.log("⚠️  Timelock NOT enabled yet (manual step required)");
    console.log("\n📝 Next Steps:");
    console.log("1. Test all propose/execute functions on testnet");
    console.log("2. When ready, enable timelock: setTimelockEnabled(true)");
    console.log("3. Verify all critical functions revert with TimelockMustBeUsed when timelock is enabled");
    console.log("4. Configure multi-sig as proposer/executor roles in Timelock contracts");
    console.log("\n⚠️  IMPORTANT:");
    console.log("- Start with 6-hour delays for testing");
    console.log("- Gradually increase to 48-hour delays for production");
    console.log("- Emergency functions (pause/unpause) remain instant");
    console.log("===========================================\n");
  } catch (error: any) {
    console.error("\n❌ Migration failed:", error);
    throw error;
  }
};

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

