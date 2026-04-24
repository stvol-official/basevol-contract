import { ethers, network, run, upgrades } from "hardhat";
import input from "@inquirer/input";

/*
 ⚠️  LEGACY SCRIPT - FOR BACKUP PURPOSES ONLY ⚠️
 
 This script upgrades BaseVolOneMin (Lazer) using the OLD UUPS proxy pattern.
 The project has been migrated to Diamond Pattern.
 
 For NEW upgrades, use:
   npx hardhat run --network base_sepolia scripts/basevol/upgrade-basevol-facet.ts
   npx hardhat run --network base scripts/basevol/upgrade-basevol-facet.ts
 
 Only use this script if you specifically need to upgrade a legacy UUPS proxy.
 
 Original commands (LEGACY):
   npx hardhat run --network base_sepolia scripts/upgrade-basevol-lazer-1min.ts
   npx hardhat run --network base scripts/upgrade-basevol-lazer-1min.ts
*/

const NETWORK = ["base_sepolia", "base"];
const DEPLOYED_PROXY = "0x31e82Ce63b81c83E9eD1838B575F720BCD87029e"; // for testnet
// const DEPLOYED_PROXY = "0xaECB62F8249D57fc1BDa3B453B67b3497FDcd4AE"; // for mainnet

function explorerAddressUrl(networkName: string, address: string): string {
  if (networkName === "base") {
    return `https://basescan.org/address/${address}#code`;
  }
  return `https://sepolia.basescan.org/address/${address}#code`;
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

const upgrade = async () => {
  // Show legacy warning at the start
  console.log("\n" + "=".repeat(80));
  console.log("⚠️  LEGACY UPGRADE SCRIPT WARNING ⚠️");
  console.log("=".repeat(80));
  console.log("This script upgrades BaseVolOneMin (Lazer) using the LEGACY UUPS proxy pattern.");
  console.log("");
  console.log("The project has migrated to Diamond Pattern.");
  console.log("For NEW upgrades, please use:");
  console.log("  npx hardhat run --network <network> scripts/basevol/upgrade-basevol-facet.ts");
  console.log("=".repeat(80) + "\n");

  const shouldContinue = await input({
    message: "Are you sure you want to upgrade using the LEGACY UUPS pattern? (yes/no)",
    default: "no",
    validate: (val) => {
      return ["yes", "no", "y", "n"].includes(val.toLowerCase()) || "Please enter yes or no";
    },
  });

  if (!["yes", "y"].includes(shouldContinue.toLowerCase())) {
    console.log("❌ Upgrade cancelled by user");
    console.log("💡 Please use: scripts/basevol/upgrade-basevol-facet.ts");
    process.exit(0);
  }
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name;
  const contractName = "BaseVolOneMin";

  const PROXY = await input({
    message: "Enter the proxy address",
    default: DEPLOYED_PROXY,
    validate: (val) => {
      return ethers.isAddress(val);
    },
  });

  const isSafeOwner = await input({
    message: "Is the owner safe address?",
    default: "N",
  });

  // Check if the network is supported.
  if (NETWORK.includes(networkName)) {
    console.log(`Upgrading to ${networkName} network...`);

    // Clean and compile so the latest source is always used (avoids stale cache).
    await run("clean");
    await run("compile");
    console.log("Compiled contracts...");

    const BaseVolFactory = await ethers.getContractFactory(contractName);

    const baseVolContract = await upgrades.forceImport(PROXY, BaseVolFactory, { kind: "uups" });

    let baseVolContractAddress;
    let addressToVerify: string;
    if (isSafeOwner === "N") {
      const baseVolContract = await upgrades.upgradeProxy(PROXY, BaseVolFactory, {
        kind: "uups",
        redeployImplementation: "always",
      });
      await baseVolContract.waitForDeployment();
      baseVolContractAddress = await baseVolContract.getAddress();
      addressToVerify = await upgrades.erc1967.getImplementationAddress(baseVolContractAddress);
      console.log(`🍣 ${contractName} Contract upgraded at ${baseVolContractAddress}`);
      console.log(`   New implementation (check this address on explorer): ${addressToVerify}`);
      console.log(`   → ${explorerAddressUrl(networkName, addressToVerify)}`);
    } else {
      const baseVolContract = await upgrades.prepareUpgrade(PROXY, BaseVolFactory, {
        kind: "uups",
        redeployImplementation: "always",
      });
      baseVolContractAddress = baseVolContract;
      addressToVerify = baseVolContract as string;
      console.log(`🍣 New implementation contract deployed at: ${baseVolContract}`);
      console.log("Use this address in your Safe transaction to upgrade the proxy");

      /**
       * Usage: https://safe.optimism.io/
       * Enter Address: 0x6022C15bE2889f9Fca24891e6df82b5A46BaC832
       * Enter ABI:
       [
          {
            "inputs": [
              {
                "internalType": "address",
                "name": "newImplementation",
                "type": "address"
              },
              {
                "internalType": "bytes",
                "name": "data",
                "type": "bytes"
              }
            ],
            "name": "upgradeToAndCall",
            "outputs": [],
            "stateMutability": "nonpayable",
            "type": "function"
          }
        ]
       * Contract Method: upgradeToAndCall(address newImplementation, bytes data)
       * newImplementation: ${baseVolContract}
       * Enter Data: 0x
       */
    }

    await sleep(6000);

    // Refresh artifacts so verify compares the same sources/settings as this run (helps avoid stale cache edge cases).
    await run("compile", { force: true });

    console.log(
      "Verifying implementation contract (Hardhat uses --network from CLI; verify later with scripts/verify-basevol-lazer-1min.ts if needed)...",
    );
    try {
      await run("verify:verify", {
        address: addressToVerify,
        contract: `contracts/core/${contractName}.sol:${contractName}`,
        constructorArguments: [],
        force: true,
      });
      console.log("Verify done.");
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      if (msg.includes("already verified") || msg.includes("ContractAlreadyVerifiedError")) {
        console.log("Implementation already verified on block explorer. Skipping.");
      } else if (msg.includes("DeployedBytecodeMismatch") || msg.includes("bytecode doesn't match")) {
        console.error("\n⚠️  Verify skipped: local bytecode does not match on-chain implementation.");
        console.error("   Upgrade already succeeded. To verify later:");
        console.error("   - Use the same git commit + npm ci as this deploy, then:");
        console.error(`     npx hardhat run --network ${networkName} scripts/verify-basevol-lazer-1min.ts`);
        console.error(`   - Or verify manually on Basescan: ${explorerAddressUrl(networkName, addressToVerify)}`);
        console.error("");
      } else {
        throw e;
      }
    }
    console.log("Proxy linking on block explorer may be done manually if needed.");
  } else {
    console.log(`Upgrading to ${networkName} network is not supported...`);
  }
};

upgrade().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
