import { ethers, network, run, upgrades } from "hardhat";
import config from "../../config";

/*
 npx hardhat run --network base_sepolia scripts/genesis-vault/deploy-genesis-strategy.ts
 npx hardhat run --network base scripts/genesis-vault/deploy-genesis-strategy.ts
*/
const NETWORK = ["base_sepolia", "base"] as const;
type SupportedNetwork = (typeof NETWORK)[number];
const GENESIS_VAULT_ADDRESS = "0x2fe04E863A3B2D991a246c70F5FE6DbF46253581";

const main = async () => {
  // Get network data from Hardhat config
  const networkName = network.name as SupportedNetwork;
  const contractName = "GenesisStrategy";

  // Check if the network is supported
  if (NETWORK.includes(networkName)) {
    console.log(`Deploying to ${networkName} network...`);

    // Check if the addresses in the config are set
    if (config.Address.ClearingHouse[networkName] === ethers.ZeroAddress) {
      throw new Error("Missing ClearingHouse address in config");
    }
    if (config.Address.Operator[networkName] === ethers.ZeroAddress) {
      throw new Error("Missing Operator address in config");
    }

    // Compile contracts
    await run("compile");

    const [deployer] = await ethers.getSigners();

    console.log("Compiled contracts...");
    console.log("===========================================");
    console.log("Owner: %s", deployer.address);
    console.log("Admin: %s", config.Address.Admin[networkName]);
    console.log("ClearingHouse: %s", config.Address.ClearingHouse[networkName]);
    console.log("Operator: %s", config.Address.Operator[networkName]);
    console.log("===========================================");

    // Deploy contracts
    const StrategyFactory = await ethers.getContractFactory(contractName);

    const initParams = [
      GENESIS_VAULT_ADDRESS,
      config.Address.ClearingHouse[networkName], // _clearingHouse
      config.Address.Operator[networkName], // _operator
    ];

    console.log("Initialization parameters:");
    console.log("- GenesisVault:", initParams[0]);
    console.log("- ClearingHouse:", initParams[1]);
    console.log("- Operator:", initParams[2]);

    const strategyContract = await upgrades.deployProxy(StrategyFactory, initParams, {
      kind: "uups",
      initializer: "initialize",
    });

    await strategyContract.waitForDeployment();
    const strategyContractAddress = await strategyContract.getAddress();
    console.log(`🏦 ${contractName} PROXY Contract deployed at ${strategyContractAddress}`);

    const network = await ethers.getDefaultProvider().getNetwork();

    console.log("Verifying contracts...");
    await run("verify:verify", {
      address: strategyContractAddress,
      network: network,
      contract: `contracts/core/vault/${contractName}.sol:${contractName}`,
      constructorArguments: [],
    });
    console.log("verify the contractAction done");

    // 배포된 컨트랙트 정보 출력
    console.log("\n Deployment Summary:");
    console.log("===========================================");
    console.log("Contract: GenesisStrategy");
    console.log("Address:", strategyContractAddress);
    console.log("Network:", networkName);
    console.log("Owner:", deployer.address);
    console.log("ClearingHouse:", config.Address.ClearingHouse[networkName]);
    console.log("Operator:", config.Address.Operator[networkName]);
    console.log("Vault:", GENESIS_VAULT_ADDRESS);
    console.log("===========================================");

    // 설정 확인
    console.log("\n🔧 Contract Configuration:");
    const maxUtilizePct = await strategyContract.maxUtilizePct();
    console.log("- Max Utilize Percentage:", ethers.formatUnits(maxUtilizePct, 18), "%");

    // 추가 정보 출력
    console.log("\n📊 Contract State:");
    console.log("- Strategy Status:", await strategyContract.strategyStatus());
    console.log("- Paused:", await strategyContract.paused());
    console.log(
      "- Utilized Assets:",
      ethers.formatUnits(await strategyContract.utilizedAssets(), 6),
    );
    console.log(
      "- Strategy Balance:",
      ethers.formatUnits(await strategyContract.strategyBalance(), 6),
    );

    console.log("\n🎉 GenesisStrategy deployment completed successfully!");
  } else {
    console.log(`Deploying to ${networkName} network is not supported...`);
  }
};

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
