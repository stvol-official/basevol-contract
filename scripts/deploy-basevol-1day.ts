import { ethers, network, run, upgrades } from "hardhat";
import input from "@inquirer/input";
import config from "../config";

/*
 ⚠️  LEGACY SCRIPT - FOR BACKUP PURPOSES ONLY ⚠️
 
 This script deploys BaseVolOneDay using the OLD UUPS proxy pattern.
 The project has been migrated to Diamond Pattern.
 
 For NEW deployments, use:
   npx hardhat run --network base_sepolia scripts/basevol/deploy-basevol-diamond.ts
   npx hardhat run --network base scripts/basevol/deploy-basevol-diamond.ts
 
 Only use this script if you specifically need to deploy using the legacy UUPS pattern.
 
 Original commands (LEGACY):
   npx hardhat run --network base_sepolia scripts/deploy-basevol-1day.ts
   npx hardhat run --network base scripts/deploy-basevol-1day.ts
*/
const NETWORK = ["base_sepolia", "base"] as const;
type SupportedNetwork = (typeof NETWORK)[number];
const main = async () => {
  // Show legacy warning at the start
  console.log("\n" + "=".repeat(80));
  console.log("⚠️  LEGACY DEPLOYMENT SCRIPT WARNING ⚠️");
  console.log("=".repeat(80));
  console.log("This script deploys BaseVolOneDay using the LEGACY UUPS proxy pattern.");
  console.log("");
  console.log("The project has migrated to Diamond Pattern.");
  console.log("For NEW deployments, please use:");
  console.log("  npx hardhat run --network <network> scripts/basevol/deploy-basevol-diamond.ts");
  console.log("=".repeat(80) + "\n");

  const shouldContinue = await input({
    message: "Are you sure you want to deploy using the LEGACY UUPS pattern? (yes/no)",
    default: "no",
    validate: (val) => {
      return ["yes", "no", "y", "n"].includes(val.toLowerCase()) || "Please enter yes or no";
    },
  });

  if (!["yes", "y"].includes(shouldContinue.toLowerCase())) {
    console.log("❌ Deployment cancelled by user");
    console.log("💡 Please use: scripts/basevol/deploy-basevol-diamond.ts");
    process.exit(0);
  }
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name as SupportedNetwork;
  const contractName = "BaseVolOneDay";

  // Check if the network is supported.
  if (NETWORK.includes(networkName)) {
    console.log(`Deploying to ${networkName} network...`);

    // Check if the addresses in the config are set.
    if (
      config.Address.Usdc[networkName] === ethers.ZeroAddress ||
      config.Address.Oracle[networkName] === ethers.ZeroAddress ||
      config.Address.Admin[networkName] === ethers.ZeroAddress ||
      config.Address.Operator[networkName] === ethers.ZeroAddress ||
      config.Address.ClearingHouse[networkName] === ethers.ZeroAddress
    ) {
      throw new Error("Missing addresses (Pyth Oracle and/or Admin/Operator)");
    }

    // Compile contracts.
    await run("compile");

    const [deployer] = await ethers.getSigners();
    console.log("Compiled contracts...");
    console.log("===========================================");
    console.log("Owner: %s", deployer.address);
    console.log("Usdc: %s", config.Address.Usdc[networkName]);
    console.log("Oracle: %s", config.Address.Oracle[networkName]);
    console.log("Admin: %s", config.Address.Admin[networkName]);
    console.log("Operator: %s", config.Address.Operator[networkName]);
    console.log("CommissionFee: %s", config.CommissionFee[networkName]);
    console.log("ClearingHouse: %s", config.Address.ClearingHouse[networkName]);
    console.log("===========================================");

    // Deploy contracts.
    const BaseVolFactory = await ethers.getContractFactory(contractName);
    const baseVolContract = await upgrades.deployProxy(
      BaseVolFactory,
      [
        config.Address.Usdc[networkName],
        config.Address.Oracle[networkName],
        config.Address.Admin[networkName],
        config.Address.Operator[networkName],
        config.CommissionFee[networkName],
        config.Address.ClearingHouse[networkName],
      ],
      { kind: "uups" },
    );

    await baseVolContract.waitForDeployment();
    const baseVolContractAddress = await baseVolContract.getAddress();
    console.log(`🍣 ${contractName} PROXY Contract deployed at ${baseVolContractAddress}`);

    const network = await ethers.getDefaultProvider().getNetwork();

    console.log("Verifying contracts...");
    await run("verify:verify", {
      address: baseVolContractAddress,
      network: network,
      contract: `contracts/core/${contractName}.sol:${contractName}`,
      constructorArguments: [],
    });
    console.log("verify the contractAction done");
  } else {
    console.log(`Deploying to ${networkName} network is not supported...`);
  }
};

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
