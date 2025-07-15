import { ethers, network, run } from "hardhat";
import config from "../config";
import { deployDiamond } from "./deploy-diamond";

/*
 npx hardhat run --network base_sepolia scripts/deploy-diamond-oneday.ts
 npx hardhat run --network base scripts/deploy-diamond-oneday.ts
*/
const NETWORK = ["base_sepolia", "base"] as const;
type SupportedNetwork = (typeof NETWORK)[number];

const main = async () => {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name as SupportedNetwork;
  const contractName = "BaseVolOneDay (Diamond)";

  // Check if the network is supported.
  if (NETWORK.includes(networkName)) {
    console.log(`Deploying ${contractName} to ${networkName} network...`);

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

    const { diamondAddress, diamondCutFacetAddress } = await deployDiamond(
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

    const networkInfo = await ethers.getDefaultProvider().getNetwork();

    console.log("Verifying contracts...");
    try {
      await run("verify:verify", {
        address: diamondAddress,
        network: networkInfo,
        contract: "contracts/Diamond.sol:Diamond",
        constructorArguments: [deployer.address, diamondCutFacetAddress],
      });
      console.log("Diamond contract verification done");
    } catch (error) {
      console.log("Diamond verification failed:", error);
    }
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
