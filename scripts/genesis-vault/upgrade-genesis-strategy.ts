import { ethers, network, run, upgrades } from "hardhat";
import input from "@inquirer/input";

/*
 npx hardhat run --network base_sepolia scripts/genesis-vault/upgrade-genesis-strategy.ts
 npx hardhat run --network base scripts/genesis-vault/upgrade-genesis-strategy.ts
*/

const NETWORK = ["base_sepolia", "base"];
// const DEPLOYED_PROXY = "0x409433B9A91009DBC4878F70dD5DF26D37d4A8Df"; // for testnet - update with actual deployed proxy address
const DEPLOYED_PROXY = "0xd3cDA3ec2DE563DB4c169efc0b8B1786aa53E2AD"; // for mainnet - update with actual deployed proxy address

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

  const isSafeOwner = await input({
    message: "Is the owner a Safe address? (Y/N)",
    default: "N",
    validate: (val) => {
      return ["Y", "N", "y", "n", "yes", "no"].includes(val) || "Please enter Y or N";
    },
  });

  const isSafeOwnerBool = isSafeOwner.toUpperCase() === "Y" || isSafeOwner.toUpperCase() === "YES";

  // Check if the network is supported.
  if (NETWORK.includes(networkName)) {
    console.log(`Upgrading ${contractName} on ${networkName} network...`);
    console.log(`Safe Owner: ${isSafeOwnerBool ? "Yes" : "No"}`);

    // Compile contracts.
    await run("compile");
    console.log("Compiled contracts...");

    // Deploy contracts.
    const GenesisStrategyFactory = await ethers.getContractFactory(contractName);

    // Force import existing proxy to avoid storage layout conflicts
    console.log("Importing existing proxy...");
    await upgrades.forceImport(PROXY, GenesisStrategyFactory, { kind: "uups" });
    console.log("Proxy imported successfully");

    let contractAddress: string;
    let contract: any;

    if (isSafeOwnerBool) {
      // Safe 계정일 때: 새 구현만 배포하고 Safe UI에서 실행하도록 안내
      console.log("\n🔐 Safe 계정을 통한 업그레이드");
      console.log("=".repeat(60));

      console.log("Preparing upgrade (deploying new implementation only)...");
      try {
        const implementationAddress = await upgrades.prepareUpgrade(PROXY, GenesisStrategyFactory, {
          kind: "uups",
          redeployImplementation: "always",
        });
        // prepareUpgrade returns a Promise<string> or string
        contractAddress =
          typeof implementationAddress === "string"
            ? implementationAddress
            : (implementationAddress as any).address || String(implementationAddress);
        console.log(`✅ New implementation contract deployed at: ${contractAddress}`);
        console.log("\n📋 Safe에서 업그레이드를 실행하세요:");
        console.log("=".repeat(60));
        console.log("1. https://app.safe.global/ 또는 https://safe.optimism.io/ 접속");
        console.log("2. 'New transaction' 클릭");
        console.log("3. 'Contract interaction' 선택");
        console.log("4. Contract address:", PROXY);
        console.log("5. ABI 입력:");
        console.log(
          `[{"inputs":[{"internalType":"address","name":"newImplementation","type":"address"},{"internalType":"bytes","name":"data","type":"bytes"}],"name":"upgradeToAndCall","outputs":[],"stateMutability":"nonpayable","type":"function"}]`,
        );
        console.log("6. Method: upgradeToAndCall 선택");
        console.log("7. Parameters 입력:");
        console.log(`   newImplementation: ${contractAddress}`);
        console.log("   data: 0x");
        console.log("8. 트랜잭션 생성 후 멀티시그 서명");
        console.log("9. 실행");
        console.log("\n⚠️  주의사항:");
        console.log(
          "- 업그레이드 후 initializeBaseVolBalance() 및 initializeMorphoBalance()를 수동으로 호출해야 할 수 있습니다.",
        );
        console.log("- strategyBalance 일관성을 확인하세요.");
      } catch (error: any) {
        console.error("❌ Prepare upgrade failed with error:");
        console.error("Error message:", error.message);
        if (error.reason) console.error("Reason:", error.reason);
        if (error.code) console.error("Code:", error.code);
        if (error.data) console.error("Data:", error.data);
        throw error;
      }
    } else {
      // 일반 계정일 때: 자동 업그레이드 실행
      console.log("Upgrading proxy...");
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
      contractAddress = await contract.getAddress();
      console.log(`🍣 ${contractName} Contract upgraded at ${contractAddress}`);

      // 일반 계정일 때만 자동으로 검증 및 초기화 수행
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
    }

    // Contract verification
    const network = await ethers.getDefaultProvider().getNetwork();

    await sleep(6000);

    console.log("\n🔍 Verifying contracts...");
    try {
      await run("verify:verify", {
        address: contractAddress,
        network: network,
        contract: `contracts/core/vault/${contractName}.sol:${contractName}`,
        constructorArguments: [],
      });
      console.log("✅ Contract verification completed");
    } catch (error: any) {
      if (
        error.message?.includes("Already Verified") ||
        error.message?.includes("already verified")
      ) {
        console.log("ℹ️  Contract is already verified");
      } else {
        console.log("⚠️  Contract verification failed:", error.message);
      }
    }
  } else {
    console.log(`Upgrading to ${networkName} network is not supported...`);
  }
};

upgrade().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
