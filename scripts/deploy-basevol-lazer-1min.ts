import { ethers, network, run, upgrades } from "hardhat";
import config from "../config";

/*
 npx hardhat run --network base_sepolia scripts/deploy-basevol-lazer-1min.ts
 npx hardhat run --network base scripts/deploy-basevol-lazer-1min.ts
*/
const NETWORK = ["base_sepolia", "base"] as const;
type SupportedNetwork = (typeof NETWORK)[number];
const main = async () => {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name as SupportedNetwork;
  const contractName = "BaseVolOneMin";

  // Check if the network is supported.
  if (NETWORK.includes(networkName)) {
    console.log(`Deploying to ${networkName} network...`);

    // Check if the addresses in the config are set.
    if (
      config.Address.Usdc[networkName] === ethers.ZeroAddress ||
      config.Address.Admin[networkName] === ethers.ZeroAddress ||
      config.Address.Operator[networkName] === ethers.ZeroAddress ||
      config.Address.ClearingHouse[networkName] === ethers.ZeroAddress
    ) {
      throw new Error("Missing addresses (Admin/Operator)");
    }

    // Compile contracts.
    await run("compile");

    const [deployer] = await ethers.getSigners();
    console.log("Compiled contracts...");
    console.log("===========================================");
    console.log("Owner: %s", deployer.address);
    console.log("Usdc: %s", config.Address.Usdc[networkName]);
    console.log("Admin: %s", config.Address.Admin[networkName]);
    console.log("Operator: %s", config.Address.Operator[networkName]);
    console.log("ClearingHouse: %s", config.Address.ClearingHouse[networkName]);
    console.log("===========================================");

    // Deploy libraries first
    const PythLazerLibFactory = await ethers.getContractFactory("PythLazerLib");
    const pythLazerLib = await PythLazerLibFactory.deploy();
    await pythLazerLib.waitForDeployment();
    const pythLazerLibAddress = await pythLazerLib.getAddress();
    console.log(`📡 PythLazerLib deployed at ${pythLazerLibAddress}`);

    // Deploy contracts.
    const BaseVolFactory = await ethers.getContractFactory(contractName, {
      libraries: {
        PythLazerLib: pythLazerLibAddress,
      },
    });
    const baseVolContract = await upgrades.deployProxy(
      BaseVolFactory,
      [
        config.Address.Usdc[networkName],
        config.Address.Admin[networkName],
        config.Address.Operator[networkName],
        config.Address.ClearingHouse[networkName],
      ],
      { kind: "uups", initializer: "initialize", unsafeAllowLinkedLibraries: true },
    );

    await baseVolContract.waitForDeployment();
    const baseVolContractAddress = await baseVolContract.getAddress();
    console.log(`🍣 ${contractName} PROXY Contract deployed at ${baseVolContractAddress}`);

    const network = await ethers.getDefaultProvider().getNetwork();

    console.log("Verifying contracts...");
    await run("verify:verify", {
      address: baseVolContractAddress,
      network: network,
      contract: `contracts/core/${contractName}.sol:${contractName}`,
      constructorArguments: [],
    });
    console.log("verify the contractAction done");
  } else {
    console.log(`Deploying to ${networkName} network is not supported...`);
  }
};

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
