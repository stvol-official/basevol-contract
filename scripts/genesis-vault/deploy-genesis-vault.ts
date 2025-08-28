import { ethers, network, run, upgrades } from "hardhat";
import config from "../../config";

/*
 npx hardhat run --network base_sepolia scripts/genesis-vault/deploy-genesis-vault.ts
 npx hardhat run --network base scripts/genesis-vault/deploy-genesis-vault.ts
*/
const NETWORK = ["base_sepolia", "base"] as const;
type SupportedNetwork = (typeof NETWORK)[number];
const main = async () => {
  // Get network data from Hardhat config
  const networkName = network.name as SupportedNetwork;
  const contractName = "GenesisVault";

  // Check if the network is supported
  if (!NETWORK.includes(networkName)) {
    console.log(`Deploying to ${networkName} network is not supported...`);
    return;
  }

  console.log(`Deploying to ${networkName} network...`);

  // Check if the addresses in the config are set
  if (config.Address.Operator[networkName] === ethers.ZeroAddress) {
    throw new Error("Missing addresses (Operator)");
  }
  if (config.Address.Usdc[networkName] === ethers.ZeroAddress) {
    throw new Error("Missing USDC address in config");
  }

  // Compile contracts
  await run("compile");

  const [deployer] = await ethers.getSigners();

  console.log("Compiled contracts...");
  console.log("===========================================");
  console.log("Owner: %s", deployer.address);
  console.log("Operator: %s", config.Address.Operator[networkName]);
  console.log("USDC: %s", config.Address.Usdc[networkName]);
  console.log("===========================================");

  // Deploy contracts
  const GenesisVaultFactory = await ethers.getContractFactory(contractName);

  // 초기화 파라미터
  const initParams = [
    config.Address.Usdc[networkName], // asset_ (USDC)
    ethers.parseEther("0.01"), // entryCost_ (1%)
    ethers.parseEther("0.01"), // exitCost_ (1%)
    "Genesis Vault", // name_
    "gVAULT", // symbol_
  ];

  console.log("Initialization parameters:");
  console.log("- Asset (USDC):", initParams[0]);
  console.log("- Entry Cost:", ethers.formatEther(initParams[1]), "ETH (1%)");
  console.log("- Exit Cost:", ethers.formatEther(initParams[2]), "ETH (1%)");
  console.log("- Name:", initParams[3]);
  console.log("- Symbol:", initParams[4]);

  const genesisVault = await upgrades.deployProxy(GenesisVaultFactory, initParams, {
    kind: "uups",
  });

  await genesisVault.waitForDeployment();
  const genesisVaultAddress = await genesisVault.getAddress();
  console.log(`🏦 ${contractName} PROXY Contract deployed at ${genesisVaultAddress}`);

  const networkInfo = await ethers.getDefaultProvider().getNetwork();

  console.log("Verifying contracts...");
  await run("verify:verify", {
    address: genesisVaultAddress,
    network: networkInfo,
    contract: `contracts/core/vault/${contractName}.sol:${contractName}`,
    constructorArguments: [],
  });
  console.log("verify the contractAction done");

  // 배포된 컨트랙트 정보 출력
  console.log("\n Deployment Summary:");
  console.log("===========================================");
  console.log("Contract:", contractName);
  console.log("Address:", genesisVaultAddress);
  console.log("Network:", networkName);
  console.log("Owner:", config.Address.Operator[networkName]);
  console.log("Asset:", config.Address.Usdc[networkName]);
  console.log("Entry Cost: 1%");
  console.log("Exit Cost: 1%");
  console.log("===========================================");

  // 추가 정보 출력
  console.log("\n📊 Contract State:");
  try {
    console.log("- Asset:", await genesisVault.asset());
    console.log("- Owner:", await genesisVault.owner());
    console.log("- Entry Cost:", ethers.formatEther(await genesisVault.entryCost()), "ETH");
    console.log("- Exit Cost:", ethers.formatEther(await genesisVault.exitCost()), "ETH");
    console.log("- Name:", await genesisVault.name());
    console.log("- Symbol:", await genesisVault.symbol());
    console.log("- Admin:", await genesisVault.admin());
    console.log("- Strategy:", await genesisVault.strategy());
    console.log("- Total Assets:", ethers.formatEther(await genesisVault.totalAssets()), "USDC");
    console.log("- Total Supply:", ethers.formatEther(await genesisVault.totalSupply()), "Shares");
  } catch (error) {
    console.log("⚠️ Could not read some contract state:", error);
  }

  console.log("\n🎉 GenesisVault deployment completed successfully!");
};

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
