import { ethers, network, run, upgrades } from "hardhat";
import input from "@inquirer/input";

/*
 npx hardhat run --network base_sepolia scripts/genesis-vault/upgrade-genesis-vault.ts
 npx hardhat run --network base scripts/genesis-vault/upgrade-genesis-vault.ts
*/

const NETWORK = ["base_sepolia", "base"];
const DEPLOYED_PROXY = "0x2fe04E863A3B2D991a246c70F5FE6DbF46253581"; // for testnet - 실제 배포된 주소로 설정 필요
// const DEPLOYED_PROXY = "0x..."; // for mainnet - 실제 배포된 주소로 설정 필요

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

const upgrade = async () => {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name;
  const contractName = "GenesisVault";

  const PROXY = await input({
    message: "Enter the proxy address",
    default: DEPLOYED_PROXY, // 기본값 없음 - 사용자가 입력해야 함
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
    const GenesisVaultFactory = await ethers.getContractFactory(contractName);

    try {
      // Force import existing proxy if needed
      await upgrades.forceImport(PROXY, GenesisVaultFactory, { kind: "uups" });
      console.log("Force import completed...");
    } catch (error) {
      console.log("Force import not needed or failed, proceeding with upgrade...");
    }

    const contract = await upgrades.upgradeProxy(PROXY, GenesisVaultFactory, {
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
      console.log("Contract verification completed successfully");
    } catch (error) {
      console.log("Contract verification failed or not needed:", error);
    }

    console.log("Upgrade process completed successfully!");
  } else {
    console.log(`Deploying to ${networkName} network is not supported...`);
  }
};

upgrade().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
