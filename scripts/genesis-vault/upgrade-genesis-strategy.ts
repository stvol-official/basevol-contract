import { ethers, network, run, upgrades } from "hardhat";
import input from "@inquirer/input";

/*
 npx hardhat run --network base_sepolia scripts/genesis-vault/upgrade-genesis-strategy.ts
 npx hardhat run --network base scripts/genesis-vault/upgrade-genesis-strategy.ts
*/

const NETWORK = ["base_sepolia", "base"];
const DEPLOYED_PROXY = "0x91d9Cf3Ee90e757dA6B01E896BD60D281bc6E93a"; // for testnet - 실제 배포된 프록시 주소로 교체 필요
// const DEPLOYED_PROXY = "0x..."; // for mainnet - 실제 배포된 프록시 주소로 교체 필요

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
    await upgrades.forceImport(PROXY, GenesisStrategyFactory, { kind: "uups" });

    // Upgrade the proxy with new implementation
    const contract = await upgrades.upgradeProxy(PROXY, GenesisStrategyFactory, {
      kind: "uups",
      redeployImplementation: "always",
    });

    await contract.waitForDeployment();
    const contractAddress = await contract.getAddress();
    console.log(`🍣 ${contractName} Contract upgraded at ${contractAddress}`);

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
