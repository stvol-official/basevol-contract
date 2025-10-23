import { ethers, network, run, upgrades } from "hardhat";
import config from "../../config";

/*
 npx hardhat run --network base scripts/genesis-vault/deploy-genesis-morpho-manager.ts
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

  console.log(`Deploying MorphoVaultManager to ${networkName} network...`);

  // Check if the addresses in the config are set
  if (config.Address.Admin[networkName] === ethers.ZeroAddress) {
    throw new Error("Missing Admin address in config");
  }
  if (config.Address.Usdc[networkName] === ethers.ZeroAddress) {
    throw new Error("Missing USDC address in config");
  }
  if (config.Address.Strategy[networkName] === ethers.ZeroAddress) {
    throw new Error("Missing Strategy address in config");
  }
  if (config.Address.MorphoVault[networkName] === ethers.ZeroAddress) {
    throw new Error(
      `Missing Morpho Vault address for ${networkName} network. Please update config.ts`,
    );
  }

  // Compile contracts
  await run("compile");

  const [deployer] = await ethers.getSigners();

  console.log("Compiled contracts...");
  console.log("===========================================");
  console.log("Deployer: %s", deployer.address);
  console.log("Admin: %s", config.Address.Admin[networkName]);
  console.log("USDC: %s", config.Address.Usdc[networkName]);
  console.log("Morpho Vault: %s", config.Address.MorphoVault[networkName]);
  console.log("Strategy: %s", config.Address.Strategy[networkName]);
  console.log("===========================================");

  try {
    // Deploy MorphoVaultManager
    console.log("\n🚀 Deploying MorphoVaultManager...");
    const MorphoVaultManager = await ethers.getContractFactory("MorphoVaultManager");

    const initParams = [
      config.Address.MorphoVault[networkName], // _morphoVault
      config.Address.Strategy[networkName], // _strategy
    ];

    console.log("Initialization parameters:");
    console.log("- Morpho Vault:", initParams[0]);
    console.log("- Strategy:", initParams[1]);

    // Deploy proxy contract
    const morphoVaultManager = (await upgrades.deployProxy(MorphoVaultManager, initParams, {
      kind: "uups",
      initializer: "initialize",
    })) as any;

    await morphoVaultManager.waitForDeployment();
    const morphoVaultManagerAddress = await morphoVaultManager.getAddress();

    console.log(`✅ MorphoVaultManager deployed at ${morphoVaultManagerAddress}`);

    // Contract verification
    console.log("\n📝 Verifying contract...");
    try {
      await run("verify:verify", {
        address: morphoVaultManagerAddress,
        contract: "contracts/core/vault/MorphoVaultManager.sol:MorphoVaultManager",
        constructorArguments: [],
      });
      console.log("✅ Contract verified successfully");
    } catch (error) {
      console.log("⚠️ Contract verification failed:", error);
    }

    // Print deployed contract information
    console.log("\n📊 Deployment Summary:");
    console.log("===========================================");
    console.log("Contract: MorphoVaultManager");
    console.log("Address:", morphoVaultManagerAddress);
    console.log("Network:", networkName);
    console.log("Owner:", deployer.address);
    console.log("Asset (USDC):", config.Address.Usdc[networkName]);
    console.log("Morpho Vault:", config.Address.MorphoVault[networkName]);
    console.log("Strategy:", config.Address.Strategy[networkName]);
    console.log("===========================================");

    // Check configuration
    console.log("\n🔧 Contract Configuration:");
    const [maxStrategyDeposit, minStrategyDeposit] = await morphoVaultManager.config();
    const totalUtilized = await morphoVaultManager.totalUtilized();
    const totalDeposited = await morphoVaultManager.totalDeposited();
    const morphoAssetBalance = await morphoVaultManager.morphoAssetBalance();
    const morphoShareBalance = await morphoVaultManager.morphoShareBalance();

    console.log("- Max Strategy Deposit:", ethers.formatUnits(maxStrategyDeposit, 6), "USDC");
    console.log("- Min Strategy Deposit:", ethers.formatUnits(minStrategyDeposit, 6), "USDC");
    console.log("- Total Utilized:", ethers.formatUnits(totalUtilized, 6), "USDC");
    console.log("- Total Deposited:", ethers.formatUnits(totalDeposited, 6), "USDC");
    console.log("- Morpho Asset Balance:", ethers.formatUnits(morphoAssetBalance, 6), "USDC");
    console.log("- Morpho Share Balance:", ethers.formatUnits(morphoShareBalance, 18), "shares");

    console.log("\n🎉 MorphoVaultManager deployment completed successfully!");

    // Call setMorphoVaultManager on GenesisStrategy
    console.log("\n🔧 Setting MorphoVaultManager on GenesisStrategy...");
    const genesisStrategy = await ethers.getContractAt(
      "GenesisStrategy",
      config.Address.Strategy[networkName],
    );

    const setMorphoVaultManagerTx =
      await genesisStrategy.setMorphoVaultManager(morphoVaultManagerAddress);
    await setMorphoVaultManagerTx.wait();

    console.log("✅ MorphoVaultManager set successfully on GenesisStrategy");
    console.log("Transaction hash:", setMorphoVaultManagerTx.hash);

    // Verify the setup
    console.log("\n🔍 Verifying setup...");
    const morphoVaultManagerFromStrategy = await genesisStrategy.morphoVaultManager();
    console.log("MorphoVaultManager from Strategy:", morphoVaultManagerFromStrategy);

    if (morphoVaultManagerFromStrategy.toLowerCase() === morphoVaultManagerAddress.toLowerCase()) {
      console.log("✅ Setup verification successful!");
    } else {
      console.log("⚠️ Setup verification failed - addresses don't match");
    }

    console.log("\n===========================================");
    console.log("🎊 All deployment steps completed!");
    console.log("===========================================");
  } catch (error) {
    console.error("❌ Deployment failed:", error);
    throw error;
  }
};

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
