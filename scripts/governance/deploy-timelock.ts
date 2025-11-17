import { ethers, network, run } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/*
 npx hardhat run --network base_sepolia scripts/governance/deploy-timelock.ts
 npx hardhat run --network base scripts/governance/deploy-timelock.ts
*/

// ============ Timelock Delay Configuration ============
// These values can be easily adjusted based on deployment stage

// Initial delays (for initial deployment and testing)
const CRITICAL_DELAY_HOURS_INITIAL = 6; // 6 hours for fund-impacting operations
const STANDARD_DELAY_HOURS_INITIAL = 2; // 2 hours for UX-impacting operations

// Target delays (after 6-12 months of stable operation)
const CRITICAL_DELAY_HOURS_TARGET = 48; // 48 hours for fund-impacting operations
const STANDARD_DELAY_HOURS_TARGET = 12; // 12 hours for UX-impacting operations

// Current deployment configuration
// Change these to TARGET values when ready to increase delays
const CRITICAL_DELAY_HOURS = CRITICAL_DELAY_HOURS_INITIAL;
const STANDARD_DELAY_HOURS = STANDARD_DELAY_HOURS_INITIAL;

// Convert hours to seconds
const CRITICAL_DELAY_SECONDS = CRITICAL_DELAY_HOURS * 60 * 60;
const STANDARD_DELAY_SECONDS = STANDARD_DELAY_HOURS * 60 * 60;

// ======================================================

const NETWORK = ["base_sepolia", "base"] as const;
type SupportedNetwork = (typeof NETWORK)[number];

const main = async () => {
  // Get network data from Hardhat config
  const networkName = network.name as SupportedNetwork;

  // Check if the network is supported
  if (!NETWORK.includes(networkName)) {
    throw new Error(`Network ${networkName} is not supported`);
  }

  console.log(`Deploying Timelock Controllers to ${networkName} network...`);

  // Multi-sig address (replace with actual multi-sig address)
  const MULTISIG_ADDRESS = process.env.MULTISIG_ADDRESS;
  if (!MULTISIG_ADDRESS) {
    throw new Error("MULTISIG_ADDRESS environment variable is not set");
  }

  // Compile contracts
  await run("compile");

  const [deployer] = await ethers.getSigners();

  console.log("Compiled contracts...");
  console.log("===========================================");
  console.log("Deployer: %s", deployer.address);
  console.log("Multi-sig: %s", MULTISIG_ADDRESS);
  console.log("Network: %s", networkName);
  console.log("===========================================");

  try {
    // Deploy Critical Timelock
    console.log("\n🚀 Deploying Critical Timelock...");
    console.log("Delay:", CRITICAL_DELAY_SECONDS, "seconds (", CRITICAL_DELAY_HOURS, "hours)");

    const TimelockController = await ethers.getContractFactory("TimelockController");
    const criticalTimelock = await TimelockController.deploy(
      CRITICAL_DELAY_SECONDS,
      [MULTISIG_ADDRESS], // proposers
      [MULTISIG_ADDRESS], // executors
      deployer.address, // admin (can be renounced later)
    );

    await criticalTimelock.waitForDeployment();
    const criticalTimelockAddress = await criticalTimelock.getAddress();
    console.log(`✅ Critical Timelock deployed at ${criticalTimelockAddress}`);

    // Deploy Standard Timelock
    console.log("\n🚀 Deploying Standard Timelock...");
    console.log("Delay:", STANDARD_DELAY_SECONDS, "seconds (", STANDARD_DELAY_HOURS, "hours)");

    const standardTimelock = await TimelockController.deploy(
      STANDARD_DELAY_SECONDS,
      [MULTISIG_ADDRESS], // proposers
      [MULTISIG_ADDRESS], // executors
      deployer.address, // admin
    );

    await standardTimelock.waitForDeployment();
    const standardTimelockAddress = await standardTimelock.getAddress();
    console.log(`✅ Standard Timelock deployed at ${standardTimelockAddress}`);

    // Contract verification
    console.log("\n🔍 Verifying contracts...");
    try {
      console.log("Verifying Critical Timelock...");
      await run("verify:verify", {
        address: criticalTimelockAddress,
        contract: "@openzeppelin/contracts/governance/TimelockController.sol:TimelockController",
        constructorArguments: [
          CRITICAL_DELAY_SECONDS,
          [MULTISIG_ADDRESS],
          [MULTISIG_ADDRESS],
          deployer.address,
        ],
      });
      console.log("✅ Critical Timelock verified successfully");
    } catch (error) {
      console.log("⚠️ Critical Timelock verification failed:", error);
    }

    try {
      console.log("Verifying Standard Timelock...");
      await run("verify:verify", {
        address: standardTimelockAddress,
        contract: "@openzeppelin/contracts/governance/TimelockController.sol:TimelockController",
        constructorArguments: [
          STANDARD_DELAY_SECONDS,
          [MULTISIG_ADDRESS],
          [MULTISIG_ADDRESS],
          deployer.address,
        ],
      });
      console.log("✅ Standard Timelock verified successfully");
    } catch (error) {
      console.log("⚠️ Standard Timelock verification failed:", error);
    }

    // Save deployment info
    const deploymentInfo = {
      network: networkName,
      chainId: (await ethers.provider.getNetwork()).chainId.toString(),
      deployer: deployer.address,
      multisig: MULTISIG_ADDRESS,
      criticalTimelock: {
        address: criticalTimelockAddress,
        delaySeconds: CRITICAL_DELAY_SECONDS,
        delayHours: CRITICAL_DELAY_HOURS,
        initialDelayHours: CRITICAL_DELAY_HOURS_INITIAL,
        targetDelayHours: CRITICAL_DELAY_HOURS_TARGET,
      },
      standardTimelock: {
        address: standardTimelockAddress,
        delaySeconds: STANDARD_DELAY_SECONDS,
        delayHours: STANDARD_DELAY_HOURS,
        initialDelayHours: STANDARD_DELAY_HOURS_INITIAL,
        targetDelayHours: STANDARD_DELAY_HOURS_TARGET,
      },
      deployedAt: new Date().toISOString(),
    };

    const deploymentPath = path.join(__dirname, "../../data/timelock-deployment.json");
    fs.mkdirSync(path.dirname(deploymentPath), { recursive: true });
    fs.writeFileSync(deploymentPath, JSON.stringify(deploymentInfo, null, 2));

    // Display role information
    console.log("\n📋 Role Information:");
    console.log("===========================================");
    const PROPOSER_ROLE = await criticalTimelock.PROPOSER_ROLE();
    const EXECUTOR_ROLE = await criticalTimelock.EXECUTOR_ROLE();
    const CANCELLER_ROLE = await criticalTimelock.CANCELLER_ROLE();
    const TIMELOCK_ADMIN_ROLE = await criticalTimelock.TIMELOCK_ADMIN_ROLE();

    console.log("PROPOSER_ROLE:", PROPOSER_ROLE);
    console.log("EXECUTOR_ROLE:", EXECUTOR_ROLE);
    console.log("CANCELLER_ROLE:", CANCELLER_ROLE);
    console.log("TIMELOCK_ADMIN_ROLE:", TIMELOCK_ADMIN_ROLE);
    console.log("===========================================");

    // Print deployment summary
    console.log("\n📊 Deployment Summary:");
    console.log("===========================================");
    console.log("Network:", networkName);
    console.log("Deployer:", deployer.address);
    console.log("Multi-sig:", MULTISIG_ADDRESS);
    console.log("\nCritical Timelock:");
    console.log("  Address:", criticalTimelockAddress);
    console.log("  Delay:", CRITICAL_DELAY_HOURS, "hours");
    console.log("  Initial Target:", CRITICAL_DELAY_HOURS_INITIAL, "hours");
    console.log("  Final Target:", CRITICAL_DELAY_HOURS_TARGET, "hours");
    console.log("\nStandard Timelock:");
    console.log("  Address:", standardTimelockAddress);
    console.log("  Delay:", STANDARD_DELAY_HOURS, "hours");
    console.log("  Initial Target:", STANDARD_DELAY_HOURS_INITIAL, "hours");
    console.log("  Final Target:", STANDARD_DELAY_HOURS_TARGET, "hours");
    console.log("\nDeployment Info Saved:", deploymentPath);
    console.log("===========================================");

    console.log("\n✅ Next Steps:");
    console.log("1. Setup multi-sig roles using setup-multisig.ts");
    console.log("2. Update contract admin addresses to use timelocks");
    console.log("3. Test timelock operations on testnet");
    console.log("4. After 6-12 months, update delays to target values");
    console.log("   - CRITICAL_DELAY_HOURS:", CRITICAL_DELAY_HOURS_TARGET, "hours");
    console.log("   - STANDARD_DELAY_HOURS:", STANDARD_DELAY_HOURS_TARGET, "hours");

    console.log("\n🎉 Timelock deployment completed successfully!");

    return {
      criticalTimelock: criticalTimelockAddress,
      standardTimelock: standardTimelockAddress,
    };
  } catch (error) {
    console.error("❌ Deployment failed:", error);
    throw error;
  }
};

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
