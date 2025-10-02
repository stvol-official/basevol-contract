import { ethers, network, run } from "hardhat";
import input from "@inquirer/input";
import config from "../config";
import { deployDiamond } from "./deploy-diamond";

/*
 ⚠️  LEGACY SCRIPT - FOR BACKUP PURPOSES ONLY ⚠️
 
 This script uses the OLD Diamond structure (contracts/Diamond.sol, contracts/facets/*).
 The project has been migrated to a NEW Diamond structure.
 
 For NEW deployments, use:
   npx hardhat run --network base_sepolia scripts/basevol/deploy-basevol-diamond.ts
   npx hardhat run --network base scripts/basevol/deploy-basevol-diamond.ts
 
 Only use this script if you specifically need to deploy using the legacy structure.
 
 Original commands (LEGACY):
   npx hardhat run --network base_sepolia scripts/deploy-diamond-oneday.ts
   npx hardhat run --network base scripts/deploy-diamond-oneday.ts
*/
const NETWORK = ["base_sepolia", "base"] as const;
type SupportedNetwork = (typeof NETWORK)[number];

const main = async () => {
  // Show legacy warning at the start
  console.log("\n" + "=".repeat(80));
  console.log("⚠️  LEGACY DEPLOYMENT SCRIPT WARNING ⚠️");
  console.log("=".repeat(80));
  console.log("This script deploys BaseVol OneDay using the LEGACY Diamond structure.");
  console.log("");
  console.log("The project has migrated to a NEW Diamond structure.");
  console.log("For NEW deployments, please use:");
  console.log("  npx hardhat run --network <network> scripts/basevol/deploy-basevol-diamond.ts");
  console.log("=".repeat(80) + "\n");

  const shouldContinue = await input({
    message: "Are you sure you want to use the LEGACY deployment script? (yes/no)",
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
  const contractName = "BaseVolOneDay (Diamond)";

  // Check if the network is supported.
  if (NETWORK.includes(networkName)) {
    console.log(`Deploying ${contractName} to ${networkName} network...`);

    const apiKey = process.env.ALCHEMY_API_KEY;
    const networkInfo = await ethers
      .getDefaultProvider(
        `https://base-${networkName === "base_sepolia" ? "sepolia" : "mainnet"}.g.alchemy.com/v2/${apiKey}`,
      )
      .getNetwork();

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
    console.log("StartTimestamp: 1751356800 (2025-07-01 08:00:00)");
    console.log("IntervalSeconds: 86400 (1 day)");
    console.log("===========================================");

    // Deploy diamond contracts with OneDay configuration
    const startTimestamp = 1751356800; // 2025-07-01 08:00:00
    const intervalSeconds = 86400; // 1 day

    const { diamondAddress, diamondCutFacetAddress, diamondInitAddress, facetAddresses } =
      await deployDiamond(
        config.Address.Usdc[networkName],
        config.Address.Oracle[networkName],
        config.Address.Admin[networkName],
        config.Address.Operator[networkName],
        config.CommissionFee[networkName],
        config.Address.ClearingHouse[networkName],
        startTimestamp,
        intervalSeconds,
      );

    console.log(`🍣 ${contractName} Diamond Contract deployed at ${diamondAddress}`);

    console.log("Verifying contracts...");

    // Verify Diamond
    try {
      await run("verify:verify", {
        address: diamondAddress,
        network: networkInfo,
        contract: "contracts/Diamond.sol:Diamond",
        constructorArguments: [deployer.address, diamondCutFacetAddress],
      });
      console.log("✅ Diamond contract verification done");
    } catch (error) {
      console.log("❌ Diamond verification failed:", error);
    }

    // Verify DiamondCutFacet
    try {
      await run("verify:verify", {
        address: diamondCutFacetAddress,
        network: networkInfo,
        contract: "contracts/facets/DiamondCutFacet.sol:DiamondCutFacet",
        constructorArguments: [],
      });
      console.log("✅ DiamondCutFacet verification done");
    } catch (error) {
      console.log("❌ DiamondCutFacet verification failed:", error);
    }

    // Verify DiamondInit
    try {
      await run("verify:verify", {
        address: diamondInitAddress,
        network: networkInfo,
        contract: "contracts/upgradeInitializers/DiamondInit.sol:DiamondInit",
        constructorArguments: [],
      });
      console.log("✅ DiamondInit verification done");
    } catch (error) {
      console.log("❌ DiamondInit verification failed:", error);
    }

    // Verify all facets
    const facetContracts = [
      {
        name: "DiamondLoupeFacet",
        path: "contracts/facets/DiamondLoupeFacet.sol:DiamondLoupeFacet",
      },
      {
        name: "InitializationFacet",
        path: "contracts/facets/InitializationFacet.sol:InitializationFacet",
      },
      {
        name: "RoundManagementFacet",
        path: "contracts/facets/RoundManagementFacet.sol:RoundManagementFacet",
      },
      {
        name: "OrderProcessingFacet",
        path: "contracts/facets/OrderProcessingFacet.sol:OrderProcessingFacet",
      },
      { name: "RedemptionFacet", path: "contracts/facets/RedemptionFacet.sol:RedemptionFacet" },
      { name: "AdminFacet", path: "contracts/facets/AdminFacet.sol:AdminFacet" },
      { name: "ViewFacet", path: "contracts/facets/ViewFacet.sol:ViewFacet" },
    ];

    for (const facet of facetContracts) {
      try {
        await run("verify:verify", {
          address: facetAddresses[facet.name],
          network: networkInfo,
          contract: facet.path,
          constructorArguments: [],
        });
        console.log(`✅ ${facet.name} verification done`);
      } catch (error) {
        console.log(`❌ ${facet.name} verification failed:`, error);
      }
    }

    console.log("\n🎉 All contract verifications completed!");
    console.log(
      "BaseScan should now automatically detect Diamond pattern and provide read/write interface.",
    );
  } else {
    console.log(`Deploying to ${networkName} network is not supported...`);
  }
};

if (require.main === module) {
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}
