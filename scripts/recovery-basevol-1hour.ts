import { ethers, network, run, upgrades } from "hardhat";

/*
 npx hardhat run --network base_sepolia scripts/recovery-basevol-1hour.ts
 npx hardhat run --network base scripts/recovery-basevol-1hour.ts
*/
const NETWORK = ["base_sepolia", "base"];
const DEPLOYED_PROXY = "0x6022C15bE2889f9Fca24891e6df82b5A46BaC832"; // for soneium_testnet
const OLD_IMPLEMENTATION_ADDRESS = "0x8a71d39Ac04EFB95b965a27675B15369149bebf5"; // for soneium_testnet
const contractName = "BaseVolOneHour";

const upgrade = async () => {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name;

  // Check if the network is supported.
  if (NETWORK.includes(networkName)) {
    console.log(`Deploying to ${networkName} network...`);

    // Compile contracts.
    await run("compile");
    console.log("Compiled contracts...");

    // Deploy contracts.
    const Proxy = await ethers.getContractAt(contractName, DEPLOYED_PROXY);
    console.log("Reverting to old implementation...");
    await Proxy.upgradeToAndCall(OLD_IMPLEMENTATION_ADDRESS, "0x");
    console.log("Proxy successfully reverted to old implementation!");
  } else {
    console.log(`Deploying to ${networkName} network is not supported...`);
  }
};

upgrade().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
