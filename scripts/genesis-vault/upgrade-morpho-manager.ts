import { ethers, network, run, upgrades } from "hardhat";
import input from "@inquirer/input";

/*
 npx hardhat run --network base_sepolia scripts/genesis-vault/upgrade-morpho-manager.ts
 npx hardhat run --network base scripts/genesis-vault/upgrade-morpho-manager.ts
*/

const NETWORK = ["base_sepolia", "base"];
const DEPLOYED_PROXY = "0xEb1929190C8DecB97Fb0744A818a3C4D9d2d0455"; // update with actual deployed address

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

const upgrade = async () => {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name;
  const contractName = "MorphoVaultManager";

  const PROXY = await input({
    message: "Enter the proxy address",
    default: DEPLOYED_PROXY,
    validate: (val) => {
      return ethers.isAddress(val);
    },
  });

  // Check if the network is supported.
  if (NETWORK.includes(networkName)) {
    console.log(`Upgrading ${contractName} on ${networkName} network...`);

    // Compile contracts.
    await run("compile");
    console.log("Compiled contracts...");

    // Deploy contracts.
    const MorphoVaultManagerFactory = await ethers.getContractFactory(contractName);

    // Force import if needed for existing proxy
    try {
      await upgrades.forceImport(PROXY, MorphoVaultManagerFactory, { kind: "uups" });
      console.log("Force import completed...");
    } catch (error: any) {
      console.log("Force import not needed or failed:", error.message);
    }

    // Upgrade the proxy
    const contract = await upgrades.upgradeProxy(PROXY, MorphoVaultManagerFactory, {
      kind: "uups",
      redeployImplementation: "always",
    });

    await contract.waitForDeployment();
    const contractAddress = await contract.getAddress();
    console.log(`🍣 ${contractName} Contract upgraded at ${contractAddress}`);

    const network = await ethers.getDefaultProvider().getNetwork();

    await sleep(6000);

    console.log("Verifying contracts...");
    try {
      await run("verify:verify", {
        address: contractAddress,
        network: network,
        contract: `contracts/core/vault/${contractName}.sol:${contractName}`,
        constructorArguments: [],
      });
      console.log("Contract verification completed");
    } catch (error: any) {
      console.log("Verification failed:", error.message);
    }

    console.log("Upgrade completed successfully!");
  } else {
    console.log(`Upgrading on ${networkName} network is not supported...`);
  }
};

upgrade().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
