import { ethers, network, run, upgrades } from "hardhat";
import input from "@inquirer/input";

/*
 npx hardhat run --network base_sepolia scripts/genesis-vault/upgrade-basevol-manager.ts
 npx hardhat run --network base scripts/genesis-vault/upgrade-basevol-manager.ts
*/

const NETWORK = ["base_sepolia", "base"];
// const DEPLOYED_PROXY = "0xa66f6081526e60742d725F6b4E6eB4e2aCB4074D"; // for testnet - update with actual deployed address
const DEPLOYED_PROXY = "0x61b596A14ae170A4304266B1a17b3273D9aFc08C"; // for mainnet - update with actual deployed address

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

const upgrade = async () => {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name;
  const contractName = "BaseVolManager";

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
    const BaseVolManagerFactory = await ethers.getContractFactory(contractName);

    // Force import if needed for existing proxy
    try {
      await upgrades.forceImport(PROXY, BaseVolManagerFactory, { kind: "uups" });
      console.log("Force import completed...");
    } catch (error: any) {
      console.log("Force import not needed or failed:", error.message);
    }

    let contractAddress: string;
    let contract: any;

    if (isSafeOwnerBool) {
      // Safe 계정일 때: 새 구현만 배포하고 Safe UI에서 실행하도록 안내
      console.log("\n🔐 Safe 계정을 통한 업그레이드");
      console.log("=".repeat(60));

      console.log("Preparing upgrade (deploying new implementation only)...");
      try {
        const implementationAddress = await upgrades.prepareUpgrade(PROXY, BaseVolManagerFactory, {
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
        contract = await upgrades.upgradeProxy(PROXY, BaseVolManagerFactory, {
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

    console.log("\n✅ Upgrade completed successfully!");
  } else {
    console.log(`Upgrading on ${networkName} network is not supported...`);
  }
};

upgrade().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
