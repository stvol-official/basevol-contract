import { ethers, network, run, upgrades } from "hardhat";
import input from "@inquirer/input";

/*
 npx hardhat run --network base_sepolia scripts/upgrade-basevol-lazer-1hour.ts
 npx hardhat run --network base scripts/upgrade-basevol-lazer-1hour.ts
*/

const NETWORK = ["base_sepolia", "base"];
const DEPLOYED_PROXY = "0x26b0A1e85f66C4864d6ABB3B146714494B56A673"; // for testnet
const PYTH_LAZER_LIB_ADDRESS = "0xB399824A08b1BECb58a499ac1D987f7441317204"; // for testnet
// const DEPLOYED_PROXY = "0xD340fEC755B03615543Cf25676847194Be18b91E"; // for mainnet
// const PYTH_LAZER_LIB_ADDRESS = "0x798f4c5c88677d38F46D9Aa70F2ae32187AA9069"; // for mainnet

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

const upgrade = async () => {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name;
  const contractName = "BaseVolOneHour";

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

    // Compile contracts.
    await run("compile");
    console.log("Compiled contracts...");

    // Use existing library address instead of deploying new one
    console.log(`📡 Using existing PythLazerLib at ${PYTH_LAZER_LIB_ADDRESS}`);

    // Deploy contracts with existing library linking
    const BaseVolFactory = await ethers.getContractFactory(contractName, {
      libraries: {
        PythLazerLib: PYTH_LAZER_LIB_ADDRESS,
      },
    });

    const baseVolContract = await upgrades.forceImport(PROXY, BaseVolFactory, {
      kind: "uups",
    });

    let baseVolContractAddress;
    if (isSafeOwner === "N") {
      const baseVolContract = await upgrades.upgradeProxy(PROXY, BaseVolFactory, {
        kind: "uups",
        redeployImplementation: "always",
        unsafeAllowLinkedLibraries: true,
      });
      await baseVolContract.waitForDeployment();
      baseVolContractAddress = await baseVolContract.getAddress();
      console.log(`🍣 ${contractName} Contract upgraded at ${baseVolContractAddress}`);
    } else {
      const baseVolContract = await upgrades.prepareUpgrade(PROXY, BaseVolFactory, {
        kind: "uups",
        redeployImplementation: "always",
        unsafeAllowLinkedLibraries: true,
      });
      baseVolContractAddress = baseVolContract;
      console.log(`�� New implementation contract deployed at: ${baseVolContract}`);
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

    const network = await ethers.getDefaultProvider().getNetwork();

    await sleep(6000);

    console.log("Verifying contracts...");
    await run("verify:verify", {
      address: baseVolContractAddress,
      network: network,
      contract: `contracts/core/${contractName}.sol:${contractName}`,
      constructorArguments: [],
    });
    console.log("verify the contractAction done");
  } else {
    console.log(`Upgrading to ${networkName} network is not supported...`);
  }
};

upgrade().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
