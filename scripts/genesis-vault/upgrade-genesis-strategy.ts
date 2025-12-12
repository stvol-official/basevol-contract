import { ethers, network, run, upgrades } from "hardhat";
import input from "@inquirer/input";

/*
 npx hardhat run --network base_sepolia scripts/genesis-vault/upgrade-genesis-strategy.ts
 npx hardhat run --network base scripts/genesis-vault/upgrade-genesis-strategy.ts
*/

const NETWORK = ["base_sepolia", "base"];
const DEPLOYED_PROXY = "0x409433B9A91009DBC4878F70dD5DF26D37d4A8Df"; // for testnet - update with actual deployed proxy address
// const DEPLOYED_PROXY = "0x..."; // for mainnet - update with actual deployed proxy address

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

const upgrade = async () => {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name;
  const contractName = "GenesisStrategy";

  const PROXY = await input({
    message: "Enter the proxy address",
    default: DEPLOYED_PROXY,
    validate: (val) => {
      return ethers.isAddress(val);
    },
  });

  // Check if the network is supported.
  if (NETWORK.includes(networkName)) {
    console.log(`Deploying to ${networkName} network...`);

    // Compile contracts.
    await run("compile");
    console.log("Compiled contracts...");

    // Deploy contracts.
    const GenesisStrategyFactory = await ethers.getContractFactory(contractName);

    // Force import existing proxy to avoid storage layout conflicts
    console.log("Importing existing proxy...");
    await upgrades.forceImport(PROXY, GenesisStrategyFactory, { kind: "uups" });
    console.log("Proxy imported successfully");

    // Upgrade the proxy with new implementation
    console.log("Upgrading proxy...");
    let contract;
    try {
      contract = await upgrades.upgradeProxy(PROXY, GenesisStrategyFactory, {
        kind: "uups",
        redeployImplementation: "always",
      });
      console.log("Upgrade transaction sent");
    } catch (error: any) {
      console.error("❌ Upgrade failed with error:");
      console.error("Error message:", error.message);
      if (error.reason) console.error("Reason:", error.reason);
      if (error.code) console.error("Code:", error.code);
      if (error.data) console.error("Data:", error.data);
      throw error;
    }

    await contract.waitForDeployment();
    const contractAddress = await contract.getAddress();
    console.log(`🍣 ${contractName} Contract upgraded at ${contractAddress}`);

    // Verify strategyBalance consistency after upgrade
    console.log("\n📊 Verifying strategy balance consistency...");

    try {
      const currentAssets = await contract.getTotalUtilizedAssets();
      const strategyBalance = await contract.strategyBalance();
      const baseVolAssets = await contract.getBaseVolAssets();
      const morphoAssets = await contract.getMorphoAssets();

      console.log(`\nCurrent assets breakdown:`);
      console.log(`  - BaseVol: ${ethers.formatUnits(baseVolAssets, 6)} USDC`);
      console.log(`  - Morpho: ${ethers.formatUnits(morphoAssets, 6)} USDC`);
      console.log(`  - Total: ${ethers.formatUnits(currentAssets, 6)} USDC`);
      console.log(`\nRecorded strategy balance: ${ethers.formatUnits(strategyBalance, 6)} USDC`);

      const discrepancy =
        currentAssets > strategyBalance
          ? currentAssets - strategyBalance
          : strategyBalance - currentAssets;

      console.log(`Discrepancy: ${ethers.formatUnits(discrepancy, 6)} USDC`);

      // If discrepancy > 1 USDC, suggest reset
      if (discrepancy > ethers.parseUnits("1", 6)) {
        console.log("\n⚠️  Significant discrepancy detected!");
        console.log("Consider calling resetStrategyBalance() to fix.");
        console.log("This will reset PnL tracking to zero.");
      } else {
        console.log("\n✅ Strategy balance is consistent with current assets.");
      }
    } catch (error: any) {
      console.log("\n⚠️  Could not verify strategy balance.");
      console.log(error);
    }

    // Initialize baseVolInitialBalance and morphoInitialBalance after upgrade
    console.log("\n📊 Checking assets for initialization...");

    // Initialize BaseVol
    try {
      const baseVolAssets = await contract.getBaseVolAssets();
      console.log(`Current BaseVol assets: ${ethers.formatUnits(baseVolAssets, 6)} USDC`);

      if (baseVolAssets > BigInt(0)) {
        console.log("\n⚠️  BaseVol has existing assets. Initializing baseVolInitialBalance...");

        const initTx = await contract.initializeBaseVolBalance();
        console.log(`Transaction hash: ${initTx.hash}`);
        await initTx.wait();

        console.log("✅ baseVolInitialBalance initialized successfully!");
        console.log(`   Set to: ${ethers.formatUnits(baseVolAssets, 6)} USDC`);
      } else {
        console.log("✅ No BaseVol assets found. No initialization needed.");
      }
    } catch (error: any) {
      console.log("\n⚠️  Could not initialize baseVolInitialBalance automatically.");
      if (error.message?.includes("BaseVol already initialized")) {
        console.log("✅ baseVolInitialBalance was already initialized.");
      } else {
        console.log("Please call initializeBaseVolBalance() manually if needed.");
        console.log(error);
      }
    }

    // Initialize Morpho
    try {
      const morphoAssets = await contract.getMorphoAssets();
      console.log(`\nCurrent Morpho assets: ${ethers.formatUnits(morphoAssets, 6)} USDC`);

      if (morphoAssets > BigInt(0)) {
        console.log("\n⚠️  Morpho has existing assets. Initializing morphoInitialBalance...");

        const initTx = await contract.initializeMorphoBalance();
        console.log(`Transaction hash: ${initTx.hash}`);
        await initTx.wait();

        console.log("✅ morphoInitialBalance initialized successfully!");
        console.log(`   Set to: ${ethers.formatUnits(morphoAssets, 6)} USDC`);
      } else {
        console.log("✅ No Morpho assets found. No initialization needed.");
      }
    } catch (error: any) {
      console.log("\n⚠️  Could not initialize morphoInitialBalance automatically.");
      if (error.message?.includes("Already initialized")) {
        console.log("✅ morphoInitialBalance was already initialized.");
      } else {
        console.log("Please call initializeMorphoBalance() manually if needed.");
        console.log(error);
      }
    }

    const network = await ethers.getDefaultProvider().getNetwork();

    await sleep(6000);

    console.log("Verifying contracts...");
    await run("verify:verify", {
      address: contractAddress,
      network: network,
      contract: `contracts/core/vault/${contractName}.sol:${contractName}`,
      constructorArguments: [],
    });
    console.log("Contract verification completed");
  } else {
    console.log(`Upgrading to ${networkName} network is not supported...`);
  }
};

upgrade().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
