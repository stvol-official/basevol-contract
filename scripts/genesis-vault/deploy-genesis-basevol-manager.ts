import { ethers, network, run, upgrades } from "hardhat";
import config from "../../config";

/*
 npx hardhat run --network base_sepolia scripts/genesis-vault/deploy-genesis-basevol-manager.ts
 npx hardhat run --network base scripts/genesis-vault/deploy-genesis-basevol-manager.ts
*/
const NETWORK = ["base_sepolia", "base"] as const;
type SupportedNetwork = (typeof NETWORK)[number];
const GENESIS_STRATEGY_ADDRESS = "0x8CEfaC7280a5a01EB025C5F7D36BBF1438C4e54B";

const main = async () => {
  // Get network data from Hardhat config
  const networkName = network.name as SupportedNetwork;

  // Check if the network is supported
  if (!NETWORK.includes(networkName)) {
    throw new Error(`Network ${networkName} is not supported`);
  }

  console.log(`Deploying BaseVolManager to ${networkName} network...`);

  // Check if the addresses in the config are set
  if (config.Address.Admin[networkName] === ethers.ZeroAddress) {
    throw new Error("Missing Admin address in config");
  }
  if (config.Address.ClearingHouse[networkName] === ethers.ZeroAddress) {
    throw new Error("Missing ClearingHouse address in config");
  }
  if (config.Address.Usdc[networkName] === ethers.ZeroAddress) {
    throw new Error("Missing USDC address in config");
  }

  // Compile contracts
  await run("compile");

  const [deployer] = await ethers.getSigners();

  console.log("Compiled contracts...");
  console.log("===========================================");
  console.log("Deployer: %s", deployer.address);
  console.log("Admin: %s", config.Address.Admin[networkName]);
  console.log("USDC: %s", config.Address.Usdc[networkName]);
  console.log("ClearingHouse: %s", config.Address.ClearingHouse[networkName]);
  console.log("===========================================");

  try {
    // Deploy BaseVolManager
    console.log("\n🚀 Deploying BaseVolManager...");
    const BaseVolManager = await ethers.getContractFactory("BaseVolManager");

    const initParams = [
      config.Address.ClearingHouse[networkName], // _clearingHouse
      GENESIS_STRATEGY_ADDRESS,
    ];

    console.log("Initialization parameters:");
    console.log("- ClearingHouse:", initParams[0]);
    console.log("- Strategy:", initParams[1]);

    // Fixed with type casting
    const baseVolManager = (await upgrades.deployProxy(BaseVolManager, initParams, {
      kind: "uups",
      initializer: "initialize",
    })) as any;

    await baseVolManager.waitForDeployment();
    const baseVolManagerAddress = await baseVolManager.getAddress();

    console.log(`✅ BaseVolManager deployed at ${baseVolManagerAddress}`);

    // Contract verification
    console.log("\n Verifying contract...");
    try {
      await run("verify:verify", {
        address: baseVolManagerAddress,
        contract: "contracts/core/vault/BaseVolManager.sol:BaseVolManager",
        constructorArguments: [],
      });
      console.log("✅ Contract verified successfully");
    } catch (error) {
      console.log("⚠️ Contract verification failed:", error);
    }

    // Print deployed contract information
    console.log("\n Deployment Summary:");
    console.log("===========================================");
    console.log("Contract: BaseVolManager");
    console.log("Address:", baseVolManagerAddress);
    console.log("Network:", networkName);
    console.log("Owner:", deployer.address);
    console.log("Asset (USDC):", config.Address.Usdc[networkName]);
    console.log("ClearingHouse:", config.Address.ClearingHouse[networkName]);
    console.log("Strategy:", GENESIS_STRATEGY_ADDRESS);
    console.log("===========================================");

    // Check configuration
    console.log("\n🔧 Contract Configuration:");
    const [maxStrategyDeposit, minStrategyDeposit, maxTotalExposure] =
      await baseVolManager.config();
    const totalUtilized = await baseVolManager.totalUtilized();
    const totalDeposited = await baseVolManager.totalDeposited();

    console.log("- Max Strategy Deposit:", ethers.formatUnits(maxStrategyDeposit, 6), "USDC");
    console.log("- Min Strategy Deposit:", ethers.formatUnits(minStrategyDeposit, 6), "USDC");
    console.log("- Max Total Exposure:", ethers.formatUnits(maxTotalExposure, 6), "USDC");
    console.log("- Total Utilized:", ethers.formatUnits(totalUtilized, 6), "USDC");
    console.log("- Total Deposited:", ethers.formatUnits(totalDeposited, 6), "USDC");

    console.log("\n🎉 BaseVolManager deployment completed successfully!");

    // Call setBaseVolManager on GenesisStrategy
    console.log("\n🔧 Setting BaseVolManager on GenesisStrategy...");
    const genesisStrategy = await ethers.getContractAt("GenesisStrategy", GENESIS_STRATEGY_ADDRESS);

    const setBaseVolManagerTx = await genesisStrategy.setBaseVolManager(baseVolManagerAddress);
    await setBaseVolManagerTx.wait();

    console.log("✅ BaseVolManager set successfully on GenesisStrategy");
    console.log("Transaction hash:", setBaseVolManagerTx.hash);
  } catch (error) {
    console.error("❌ Deployment failed:", error);
    throw error;
  }
};

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
