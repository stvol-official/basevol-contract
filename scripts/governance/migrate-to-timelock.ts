import { ethers, network, run } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/*
 npx hardhat run --network base_sepolia scripts/governance/migrate-to-timelock.ts
 npx hardhat run --network base scripts/governance/migrate-to-timelock.ts
*/

const NETWORK = ["base_sepolia", "base"] as const;
type SupportedNetwork = (typeof NETWORK)[number];

const main = async () => {
  // Get network data from Hardhat config
  const networkName = network.name as SupportedNetwork;

  // Check if the network is supported
  if (!NETWORK.includes(networkName)) {
    throw new Error(`Network ${networkName} is not supported`);
  }

  console.log(`Migrating contracts to Timelock on ${networkName} network...`);
  console.log("⚠️  WARNING: This is a critical operation. Test thoroughly on testnet first!");

  // Compile contracts
  await run("compile");

  const [deployer] = await ethers.getSigners();

  // Load deployment info
  const deploymentPath = path.join(__dirname, "../../data/timelock-deployment.json");
  if (!fs.existsSync(deploymentPath)) {
    throw new Error("Timelock deployment info not found. Run deploy-timelock.ts first.");
  }

  const deploymentInfo = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));
  const CRITICAL_TIMELOCK = deploymentInfo.criticalTimelock.address;
  const STANDARD_TIMELOCK = deploymentInfo.standardTimelock.address;

  // Load contract addresses from environment or config
  const BASEVOL_DIAMOND_ADDRESS = process.env.BASEVOL_DIAMOND_ADDRESS;
  const GENESIS_VAULT_ADDRESS = process.env.GENESIS_VAULT_ADDRESS;
  const CLEARING_HOUSE_ADDRESS = process.env.CLEARING_HOUSE_ADDRESS;
  const BASEVOL_MANAGER_ADDRESS = process.env.BASEVOL_MANAGER_ADDRESS;
  const GENESIS_STRATEGY_ADDRESS = process.env.GENESIS_STRATEGY_ADDRESS;

  console.log("Compiled contracts...");
  console.log("===========================================");
  console.log("Deployer: %s", deployer.address);
  console.log("Network: %s", networkName);
  console.log("\nTimelock Addresses:");
  console.log("Critical Timelock: %s", CRITICAL_TIMELOCK);
  console.log("Standard Timelock: %s", STANDARD_TIMELOCK);
  console.log("\nContract Addresses:");
  console.log("BaseVol Diamond:", BASEVOL_DIAMOND_ADDRESS || "Not set");
  console.log("Genesis Vault:", GENESIS_VAULT_ADDRESS || "Not set");
  console.log("ClearingHouse:", CLEARING_HOUSE_ADDRESS || "Not set");
  console.log("BaseVol Manager:", BASEVOL_MANAGER_ADDRESS || "Not set");
  console.log("Genesis Strategy:", GENESIS_STRATEGY_ADDRESS || "Not set");
  console.log("===========================================");

  try {
    let migratedContracts = 0;

    // BaseVol Diamond - Set timelock
    if (BASEVOL_DIAMOND_ADDRESS) {
      console.log("\n🔧 Setting timelock for BaseVol Diamond...");
      const diamondCutFacet = await ethers.getContractAt(
        "DiamondCutFacetTimelock",
        BASEVOL_DIAMOND_ADDRESS,
      );

      let tx = await diamondCutFacet.setCriticalTimelock(CRITICAL_TIMELOCK);
      await tx.wait();
      console.log("✅ Critical timelock set");

      tx = await diamondCutFacet.setTimelockEnabled(true);
      await tx.wait();
      console.log("✅ Timelock enabled");

      migratedContracts++;
    } else {
      console.log("\n⚠️  BaseVol Diamond address not set, skipping...");
    }

    // Genesis Vault - Set timelock
    if (GENESIS_VAULT_ADDRESS) {
      console.log("\n🔧 Setting timelock for Genesis Vault...");
      const genesisVaultAdmin = await ethers.getContractAt(
        "GenesisVaultAdminFacetTimelock",
        GENESIS_VAULT_ADDRESS,
      );

      let tx = await genesisVaultAdmin.setCriticalTimelock(CRITICAL_TIMELOCK);
      await tx.wait();
      console.log("✅ Critical timelock set");

      tx = await genesisVaultAdmin.setStandardTimelock(STANDARD_TIMELOCK);
      await tx.wait();
      console.log("✅ Standard timelock set");

      tx = await genesisVaultAdmin.setTimelockEnabled(true);
      await tx.wait();
      console.log("✅ Timelock enabled");

      migratedContracts++;
    } else {
      console.log("\n⚠️  Genesis Vault address not set, skipping...");
    }

    // ClearingHouse - Set timelock
    if (CLEARING_HOUSE_ADDRESS) {
      console.log("\n🔧 Setting timelock for ClearingHouse...");
      console.log("⚠️  ClearingHouse timelock integration requires contract upgrade");
      console.log("   Please upgrade ClearingHouse contract first");
    } else {
      console.log("\n⚠️  ClearingHouse address not set, skipping...");
    }

    // BaseVolManager - Set timelock
    if (BASEVOL_MANAGER_ADDRESS) {
      console.log("\n🔧 Setting timelock for BaseVolManager...");
      console.log("⚠️  BaseVolManager timelock integration requires contract upgrade");
      console.log("   Please upgrade BaseVolManager contract first");
    } else {
      console.log("\n⚠️  BaseVolManager address not set, skipping...");
    }

    // GenesisStrategy - Set timelock
    if (GENESIS_STRATEGY_ADDRESS) {
      console.log("\n🔧 Setting timelock for GenesisStrategy...");
      console.log("⚠️  GenesisStrategy timelock integration requires contract upgrade");
      console.log("   Please upgrade GenesisStrategy contract first");
    } else {
      console.log("\n⚠️  GenesisStrategy address not set, skipping...");
    }

    // Verify Timelock Setup
    console.log("\n🔍 Verifying Timelock Setup...");
    console.log("===========================================");

    if (BASEVOL_DIAMOND_ADDRESS) {
      const diamondCutFacet = await ethers.getContractAt(
        "DiamondCutFacetTimelock",
        BASEVOL_DIAMOND_ADDRESS,
      );
      const criticalTimelock = await diamondCutFacet.getCriticalTimelock();
      const isEnabled = await diamondCutFacet.isTimelockEnabled();
      console.log("BaseVol Diamond:");
      console.log("  Critical Timelock:", criticalTimelock);
      console.log("  Enabled:", isEnabled ? "✅" : "❌");
    }

    if (GENESIS_VAULT_ADDRESS) {
      const genesisVaultAdmin = await ethers.getContractAt(
        "GenesisVaultAdminFacetTimelock",
        GENESIS_VAULT_ADDRESS,
      );
      const criticalTimelock = await genesisVaultAdmin.getCriticalTimelock();
      const standardTimelock = await genesisVaultAdmin.getStandardTimelock();
      const isEnabled = await genesisVaultAdmin.isTimelockEnabled();
      console.log("\nGenesis Vault:");
      console.log("  Critical Timelock:", criticalTimelock);
      console.log("  Standard Timelock:", standardTimelock);
      console.log("  Enabled:", isEnabled ? "✅" : "❌");
    }
    console.log("===========================================");

    // Save migration info
    const migrationInfo = {
      network: networkName,
      migratedAt: new Date().toISOString(),
      deployer: deployer.address,
      criticalTimelock: CRITICAL_TIMELOCK,
      standardTimelock: STANDARD_TIMELOCK,
      contracts: {
        baseVolDiamond: BASEVOL_DIAMOND_ADDRESS || null,
        genesisVault: GENESIS_VAULT_ADDRESS || null,
        clearingHouse: CLEARING_HOUSE_ADDRESS || null,
        baseVolManager: BASEVOL_MANAGER_ADDRESS || null,
        genesisStrategy: GENESIS_STRATEGY_ADDRESS || null,
      },
      migratedContracts,
    };

    const migrationPath = path.join(__dirname, "../../data/timelock-migration.json");
    fs.mkdirSync(path.dirname(migrationPath), { recursive: true });
    fs.writeFileSync(migrationPath, JSON.stringify(migrationInfo, null, 2));

    // Print migration summary
    console.log("\n📊 Migration Summary:");
    console.log("===========================================");
    console.log("Network:", networkName);
    console.log("Migrated Contracts:", migratedContracts);
    console.log("Critical Timelock:", CRITICAL_TIMELOCK);
    console.log("Standard Timelock:", STANDARD_TIMELOCK);
    console.log("Migration Info Saved:", migrationPath);
    console.log("===========================================");

    console.log("\n✅ Important Notes:");
    console.log("1. All critical operations now require timelock delay");
    console.log("2. Emergency functions (pause/unpause) still work immediately");
    console.log("3. Test all admin operations before using in production");
    console.log("4. Monitor all timelock proposals closely");

    if (migratedContracts === 0) {
      console.log("\n⚠️  No contracts were migrated. Please set contract addresses.");
    } else {
      console.log("\n🎉 Migration completed successfully!");
    }
  } catch (error) {
    console.error("❌ Migration failed:", error);
    throw error;
  }
};

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
