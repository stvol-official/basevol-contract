import { ethers, network, run } from "hardhat";
import config from "../../config";

/*
 npx hardhat run --network base_sepolia scripts/genesis-vault/deploy-genesis-vault-diamond.ts
 npx hardhat run --network base scripts/genesis-vault/deploy-genesis-vault-diamond.ts
*/

const NETWORK = ["base_sepolia", "base"] as const;
type SupportedNetwork = (typeof NETWORK)[number];

interface DeployedContracts {
  diamond: string;
  diamondCutFacet: string;
  diamondLoupeFacet: string;
  erc20Facet: string;
  genesisVaultViewFacet: string;
  genesisVaultAdminFacet: string;
  keeperFacet: string;
  vaultCoreFacet: string;
  settlementFacet: string;
  initializationFacet: string;
}

// Helper function to wait for contract code to be available
async function waitForContractCode(
  address: string,
  maxRetries = 5,
  delayMs = 2000,
): Promise<boolean> {
  for (let i = 0; i < maxRetries; i++) {
    const code = await ethers.provider.getCode(address);
    if (code !== "0x") {
      return true;
    }
    if (i < maxRetries - 1) {
      console.log(`    ⏳ Waiting for contract code to be available... (${i + 1}/${maxRetries})`);
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }
  return false;
}

async function deployFacets() {
  console.log("\n📦 Deploying Facets (sequentially to avoid nonce issues)...");

  // Deploy DiamondCutFacet
  const DiamondCutFacet = await ethers.getContractFactory(
    "contracts/diamond-common/facets/DiamondCutFacet.sol:DiamondCutFacet",
  );
  const diamondCutFacet = await DiamondCutFacet.deploy();
  await diamondCutFacet.waitForDeployment();
  const diamondCutFacetAddress = await diamondCutFacet.getAddress();
  console.log("✅ DiamondCutFacet deployed at:", diamondCutFacetAddress);

  // Deploy DiamondLoupeFacet
  const DiamondLoupeFacet = await ethers.getContractFactory(
    "contracts/diamond-common/facets/DiamondLoupeFacet.sol:DiamondLoupeFacet",
  );
  const diamondLoupeFacet = await DiamondLoupeFacet.deploy();
  await diamondLoupeFacet.waitForDeployment();
  const diamondLoupeFacetAddress = await diamondLoupeFacet.getAddress();
  console.log("✅ DiamondLoupeFacet deployed at:", diamondLoupeFacetAddress);

  // Deploy ERC20Facet
  const ERC20Facet = await ethers.getContractFactory(
    "contracts/genesis-vault/facets/ERC20Facet.sol:ERC20Facet",
  );
  const erc20Facet = await ERC20Facet.deploy();
  await erc20Facet.waitForDeployment();
  const erc20FacetAddress = await erc20Facet.getAddress();
  console.log("✅ ERC20Facet deployed at:", erc20FacetAddress);

  // Deploy GenesisVaultViewFacet
  const GenesisVaultViewFacet = await ethers.getContractFactory(
    "contracts/genesis-vault/facets/GenesisVaultViewFacet.sol:GenesisVaultViewFacet",
  );
  const genesisVaultViewFacet = await GenesisVaultViewFacet.deploy();
  await genesisVaultViewFacet.waitForDeployment();
  const genesisVaultViewFacetAddress = await genesisVaultViewFacet.getAddress();
  console.log("✅ GenesisVaultViewFacet deployed at:", genesisVaultViewFacetAddress);

  // Deploy GenesisVaultAdminFacet
  const GenesisVaultAdminFacet = await ethers.getContractFactory(
    "contracts/genesis-vault/facets/GenesisVaultAdminFacet.sol:GenesisVaultAdminFacet",
  );
  const genesisVaultAdminFacet = await GenesisVaultAdminFacet.deploy();
  await genesisVaultAdminFacet.waitForDeployment();
  const genesisVaultAdminFacetAddress = await genesisVaultAdminFacet.getAddress();
  console.log("✅ GenesisVaultAdminFacet deployed at:", genesisVaultAdminFacetAddress);

  // Deploy KeeperFacet
  const KeeperFacet = await ethers.getContractFactory(
    "contracts/genesis-vault/facets/KeeperFacet.sol:KeeperFacet",
  );
  const keeperFacet = await KeeperFacet.deploy();
  await keeperFacet.waitForDeployment();
  const keeperFacetAddress = await keeperFacet.getAddress();
  console.log("✅ KeeperFacet deployed at:", keeperFacetAddress);

  // Deploy VaultCoreFacet
  const VaultCoreFacet = await ethers.getContractFactory(
    "contracts/genesis-vault/facets/VaultCoreFacet.sol:VaultCoreFacet",
  );
  const vaultCoreFacet = await VaultCoreFacet.deploy();
  await vaultCoreFacet.waitForDeployment();
  const vaultCoreFacetAddress = await vaultCoreFacet.getAddress();
  console.log("✅ VaultCoreFacet deployed at:", vaultCoreFacetAddress);

  // Deploy SettlementFacet
  const SettlementFacet = await ethers.getContractFactory(
    "contracts/genesis-vault/facets/SettlementFacet.sol:SettlementFacet",
  );
  const settlementFacet = await SettlementFacet.deploy();
  await settlementFacet.waitForDeployment();
  const settlementFacetAddress = await settlementFacet.getAddress();
  console.log("✅ SettlementFacet deployed at:", settlementFacetAddress);

  // Deploy GenesisVaultInitializationFacet
  const InitializationFacet = await ethers.getContractFactory(
    "contracts/genesis-vault/facets/GenesisVaultInitializationFacet.sol:GenesisVaultInitializationFacet",
  );
  const initializationFacet = await InitializationFacet.deploy();
  await initializationFacet.waitForDeployment();
  const initializationFacetAddress = await initializationFacet.getAddress();
  console.log("✅ GenesisVaultInitializationFacet deployed at:", initializationFacetAddress);

  console.log("\n⏳ Verifying contract code availability (sequentially)...");

  // Verify DiamondCutFacet
  let hasCode = await waitForContractCode(diamondCutFacetAddress);
  if (!hasCode) {
    throw new Error(`DiamondCutFacet code not available at ${diamondCutFacetAddress}`);
  }
  console.log("  ✅ DiamondCutFacet verified");

  // Verify DiamondLoupeFacet
  hasCode = await waitForContractCode(diamondLoupeFacetAddress);
  if (!hasCode) {
    throw new Error(`DiamondLoupeFacet code not available at ${diamondLoupeFacetAddress}`);
  }
  console.log("  ✅ DiamondLoupeFacet verified");

  // Verify remaining facets
  hasCode = await waitForContractCode(erc20FacetAddress);
  if (!hasCode) {
    throw new Error(`ERC20Facet code not available at ${erc20FacetAddress}`);
  }
  console.log("  ✅ ERC20Facet verified");

  hasCode = await waitForContractCode(genesisVaultViewFacetAddress);
  if (!hasCode) {
    throw new Error(`GenesisVaultViewFacet code not available at ${genesisVaultViewFacetAddress}`);
  }
  console.log("  ✅ GenesisVaultViewFacet verified");

  hasCode = await waitForContractCode(genesisVaultAdminFacetAddress);
  if (!hasCode) {
    throw new Error(
      `GenesisVaultAdminFacet code not available at ${genesisVaultAdminFacetAddress}`,
    );
  }
  console.log("  ✅ GenesisVaultAdminFacet verified");

  hasCode = await waitForContractCode(keeperFacetAddress);
  if (!hasCode) {
    throw new Error(`KeeperFacet code not available at ${keeperFacetAddress}`);
  }
  console.log("  ✅ KeeperFacet verified");

  hasCode = await waitForContractCode(vaultCoreFacetAddress);
  if (!hasCode) {
    throw new Error(`VaultCoreFacet code not available at ${vaultCoreFacetAddress}`);
  }
  console.log("  ✅ VaultCoreFacet verified");

  hasCode = await waitForContractCode(settlementFacetAddress);
  if (!hasCode) {
    throw new Error(`SettlementFacet code not available at ${settlementFacetAddress}`);
  }
  console.log("  ✅ SettlementFacet verified");

  hasCode = await waitForContractCode(initializationFacetAddress);
  if (!hasCode) {
    throw new Error(`InitializationFacet code not available at ${initializationFacetAddress}`);
  }
  console.log("  ✅ InitializationFacet verified");

  console.log("✅ All facets verified on network");

  return {
    diamondCutFacet: diamondCutFacetAddress,
    diamondLoupeFacet: diamondLoupeFacetAddress,
    erc20Facet: erc20FacetAddress,
    genesisVaultViewFacet: genesisVaultViewFacetAddress,
    genesisVaultAdminFacet: genesisVaultAdminFacetAddress,
    keeperFacet: keeperFacetAddress,
    vaultCoreFacet: vaultCoreFacetAddress,
    settlementFacet: settlementFacetAddress,
    initializationFacet: initializationFacetAddress,
  };
}

async function getSelectors(contractInterface: any, excludeSelectors: string[] = []) {
  const fragments = Object.values(contractInterface.fragments);
  const selectors = fragments
    .filter((fragment: any) => fragment.type === "function")
    .map((fragment: any) => fragment.selector)
    .filter((selector: string) => selector !== undefined)
    .filter((selector: string) => !excludeSelectors.includes(selector));

  if (selectors.length === 0) {
    console.warn(`⚠️ Warning: No selectors found for contract`);
  }

  return selectors;
}

async function deployDiamond(owner: string, facets: Omit<DeployedContracts, "diamond">) {
  console.log("\n💎 Deploying Diamond...");

  const Diamond = await ethers.getContractFactory("contracts/diamond-common/Diamond.sol:Diamond");
  const diamond = await Diamond.deploy(owner, facets.diamondCutFacet);
  await diamond.waitForDeployment();
  const diamondAddress = await diamond.getAddress();
  console.log("✅ Diamond deployed at:", diamondAddress);

  return diamondAddress;
}

async function addFacets(diamondAddress: string, facets: Omit<DeployedContracts, "diamond">) {
  console.log("\n🔧 Adding Facets to Diamond...");

  // Verify all facet addresses have code
  console.log("\n🔍 Verifying facet deployments...");
  const facetAddresses = [
    { name: "DiamondLoupeFacet", address: facets.diamondLoupeFacet },
    { name: "ERC20Facet", address: facets.erc20Facet },
    { name: "GenesisVaultViewFacet", address: facets.genesisVaultViewFacet },
    { name: "GenesisVaultAdminFacet", address: facets.genesisVaultAdminFacet },
    { name: "KeeperFacet", address: facets.keeperFacet },
    { name: "VaultCoreFacet", address: facets.vaultCoreFacet },
    { name: "SettlementFacet", address: facets.settlementFacet },
    { name: "InitializationFacet", address: facets.initializationFacet },
  ];

  for (const facet of facetAddresses) {
    const code = await ethers.provider.getCode(facet.address);
    if (code === "0x") {
      throw new Error(`❌ ${facet.name} at ${facet.address} has no code!`);
    }
    console.log(`  ✅ ${facet.name}: ${facet.address}`);
  }

  const diamondCut = await ethers.getContractAt(
    "contracts/diamond-common/interfaces/IDiamondCut.sol:IDiamondCut",
    diamondAddress,
  );

  // Prepare facet cuts
  const FacetCutAction = { Add: 0, Replace: 1, Remove: 2 };

  const cuts = [];

  // DiamondLoupeFacet
  const DiamondLoupeFacetFactory = await ethers.getContractFactory(
    "contracts/diamond-common/facets/DiamondLoupeFacet.sol:DiamondLoupeFacet",
  );
  cuts.push({
    facetAddress: facets.diamondLoupeFacet,
    action: FacetCutAction.Add,
    functionSelectors: await getSelectors(DiamondLoupeFacetFactory.interface),
  });

  // ERC20Facet
  const ERC20FacetFactory = await ethers.getContractFactory(
    "contracts/genesis-vault/facets/ERC20Facet.sol:ERC20Facet",
  );
  cuts.push({
    facetAddress: facets.erc20Facet,
    action: FacetCutAction.Add,
    functionSelectors: await getSelectors(ERC20FacetFactory.interface),
  });

  // GenesisVaultViewFacet
  const GenesisVaultViewFacetFactory = await ethers.getContractFactory(
    "contracts/genesis-vault/facets/GenesisVaultViewFacet.sol:GenesisVaultViewFacet",
  );
  cuts.push({
    facetAddress: facets.genesisVaultViewFacet,
    action: FacetCutAction.Add,
    functionSelectors: await getSelectors(GenesisVaultViewFacetFactory.interface),
  });

  // GenesisVaultAdminFacet
  const GenesisVaultAdminFacetFactory = await ethers.getContractFactory(
    "contracts/genesis-vault/facets/GenesisVaultAdminFacet.sol:GenesisVaultAdminFacet",
  );
  cuts.push({
    facetAddress: facets.genesisVaultAdminFacet,
    action: FacetCutAction.Add,
    functionSelectors: await getSelectors(GenesisVaultAdminFacetFactory.interface),
  });

  // KeeperFacet
  const KeeperFacetFactory = await ethers.getContractFactory(
    "contracts/genesis-vault/facets/KeeperFacet.sol:KeeperFacet",
  );
  cuts.push({
    facetAddress: facets.keeperFacet,
    action: FacetCutAction.Add,
    functionSelectors: await getSelectors(KeeperFacetFactory.interface),
  });

  // VaultCoreFacet (includes ERC7540 functions)
  const VaultCoreFacetFactory = await ethers.getContractFactory(
    "contracts/genesis-vault/facets/VaultCoreFacet.sol:VaultCoreFacet",
  );
  cuts.push({
    facetAddress: facets.vaultCoreFacet,
    action: FacetCutAction.Add,
    functionSelectors: await getSelectors(VaultCoreFacetFactory.interface),
  });

  // SettlementFacet
  const SettlementFacetFactory = await ethers.getContractFactory(
    "contracts/genesis-vault/facets/SettlementFacet.sol:SettlementFacet",
  );
  cuts.push({
    facetAddress: facets.settlementFacet,
    action: FacetCutAction.Add,
    functionSelectors: await getSelectors(SettlementFacetFactory.interface),
  });

  // InitializationFacet
  const InitializationFacetFactory = await ethers.getContractFactory(
    "contracts/genesis-vault/facets/GenesisVaultInitializationFacet.sol:GenesisVaultInitializationFacet",
  );

  const initSelectors = await getSelectors(InitializationFacetFactory.interface);
  console.log(
    `\n🔍 InitializationFacet selectors (${initSelectors.length}):`,
    initSelectors.map((s) => {
      const fragment = InitializationFacetFactory.interface.getFunction(s);
      return `${s} = ${fragment?.name}`;
    }),
  );
  cuts.push({
    facetAddress: facets.initializationFacet,
    action: FacetCutAction.Add,
    functionSelectors: initSelectors,
  });

  // Debug: Log the cuts and check for duplicates
  console.log(`\n📊 Preparing to add ${cuts.length} facets...`);
  const selectorMap = new Map<string, string[]>();

  for (let i = 0; i < cuts.length; i++) {
    console.log(
      `  Facet ${i + 1}: ${cuts[i].facetAddress} with ${cuts[i].functionSelectors.length} selectors`,
    );

    // Track which selectors belong to which facet
    for (const selector of cuts[i].functionSelectors) {
      if (!selectorMap.has(selector)) {
        selectorMap.set(selector, []);
      }
      selectorMap.get(selector)!.push(`Facet ${i + 1} (${cuts[i].facetAddress})`);
    }
  }

  // Check for duplicate selectors
  console.log("\n🔍 Checking for duplicate selectors...");
  let hasDuplicates = false;
  for (const [selector, facets] of selectorMap.entries()) {
    if (facets.length > 1) {
      console.error(`  ❌ Selector ${selector} appears in multiple facets:`);
      facets.forEach((facet) => console.error(`     - ${facet}`));
      hasDuplicates = true;
    }
  }

  if (!hasDuplicates) {
    console.log("  ✅ No duplicate selectors found");
  } else {
    throw new Error("Duplicate function selectors detected across facets!");
  }

  // Execute diamond cut
  console.log("\n🔪 Executing diamondCut...");
  try {
    // Estimate gas first
    const gasEstimate = await diamondCut.diamondCut.estimateGas(cuts, ethers.ZeroAddress, "0x");
    console.log(`⛽ Estimated gas: ${gasEstimate.toString()}`);

    const tx = await diamondCut.diamondCut(cuts, ethers.ZeroAddress, "0x");
    console.log(`📝 Transaction hash: ${tx.hash}`);
    console.log("⏳ Waiting for transaction confirmation...");
    const receipt = await tx.wait();
    console.log(`✅ Transaction confirmed in block ${receipt.blockNumber}`);

    // Wait for state to propagate on network
    console.log("⏳ Waiting for network state propagation...");
    await new Promise((resolve) => setTimeout(resolve, 3000));
  } catch (error: any) {
    console.error("\n❌ DiamondCut failed!");
    console.error("Error message:", error.message);

    if (error.reason) {
      console.error("Error reason:", error.reason);
    }

    if (error.data) {
      console.error("Error data:", error.data);
    }

    if (error.error) {
      console.error("Error object:", error.error);
    }

    // Try to decode the error
    if (error.data && typeof error.data === "string") {
      try {
        const errorInterface = new ethers.Interface([
          "error LibDiamond: No selectors in facet to cut",
          "error LibDiamond: Add facet can't be address(0)",
          "error LibDiamond: Add facet has no code",
          "error LibDiamond: Can't add function that already exists",
        ]);
        console.error("Decoded error:", errorInterface.parseError(error.data));
      } catch (e) {
        console.error("Could not decode error");
      }
    }

    throw error;
  }

  console.log("✅ All facets added to Diamond");

  // Verify initialize function selector is in Diamond with retry
  console.log("\n🔍 Verifying initialize function...");
  const initializeSelector = "0xd76f5fd6";
  let verified = false;

  for (let i = 0; i < 3; i++) {
    try {
      const diamondLoupe = await ethers.getContractAt(
        "contracts/diamond-common/facets/DiamondLoupeFacet.sol:DiamondLoupeFacet",
        diamondAddress,
      );
      const facetAddress = await diamondLoupe.facetAddress(initializeSelector);
      console.log(`  Initialize selector ${initializeSelector} => ${facetAddress}`);
      if (facetAddress !== ethers.ZeroAddress) {
        verified = true;
        break;
      }
    } catch (error: any) {
      if (i < 2) {
        console.log(`  ⏳ Retry ${i + 1}/2 after 3 seconds...`);
        await new Promise((resolve) => setTimeout(resolve, 3000));
      } else {
        console.error("  ❌ Failed to verify initialize function:", error.message);
        throw error;
      }
    }
  }

  if (!verified) {
    throw new Error("Initialize function not found in Diamond after retries!");
  }
  console.log("  ✅ Initialize function verified!");
}

async function initializeVault(
  diamondAddress: string,
  networkName: SupportedNetwork,
  owner: string,
) {
  console.log("\n🚀 Initializing GenesisVault...");

  const vault = await ethers.getContractAt(
    "contracts/genesis-vault/facets/GenesisVaultInitializationFacet.sol:GenesisVaultInitializationFacet",
    diamondAddress,
  );

  const initTx = await vault.initialize(
    config.Address.Usdc[networkName], // asset
    "Genesis Vault", // name
    "gVAULT", // symbol
    owner, // admin
    ethers.ZeroAddress, // baseVolContract (to be set later)
    ethers.ZeroAddress, // strategy (to be set later)
    owner, // feeRecipient
    ethers.parseEther("0.02"), // annual managementFee (2% - scaled by 1e18)
    ethers.parseEther("0.20"), // performanceFee (20% - scaled by 1e18)
    ethers.parseEther("0"), // hurdleRate (0% - scaled by 1e18)
    ethers.parseUnits("0", 6), // entryCost (0 USDC fixed cost)
    ethers.parseUnits("1", 6), // exitCost (1 USDC fixed cost)
    ethers.parseUnits("10000", 6), // userDepositLimit (10,000 USDC)
    ethers.parseUnits("1000000", 6), // vaultDepositLimit (1,000,000 USDC)
  );
  await initTx.wait();

  console.log("✅ GenesisVault initialized");

  // Verify initialization
  try {
    const erc20 = await ethers.getContractAt(
      "contracts/genesis-vault/facets/ERC20Facet.sol:ERC20Facet",
      diamondAddress,
    );
    const name = await erc20.name();
    const symbol = await erc20.symbol();
    console.log(`📝 Verified - Name: "${name}", Symbol: "${symbol}"`);
  } catch (error) {
    console.log("⚠️ Could not verify name/symbol:", error);
  }
}

const main = async () => {
  const networkName = network.name as SupportedNetwork;

  if (!NETWORK.includes(networkName)) {
    console.log(`Deploying to ${networkName} network is not supported...`);
    return;
  }

  console.log(`\n🌐 Deploying to ${networkName} network...`);

  if (config.Address.Usdc[networkName] === ethers.ZeroAddress) {
    throw new Error("Missing USDC address in config");
  }

  await run("compile");

  const [deployer] = await ethers.getSigners();

  console.log("\n===========================================");
  console.log("Owner: %s", deployer.address);
  console.log("USDC: %s", config.Address.Usdc[networkName]);
  console.log("===========================================");

  // Step 1: Deploy all facets
  const facets = await deployFacets();

  // Step 2: Deploy Diamond
  const diamondAddress = await deployDiamond(deployer.address, facets);

  // Step 3: Add facets to Diamond
  await addFacets(diamondAddress, facets);

  // Step 4: Initialize vault
  await initializeVault(diamondAddress, networkName, deployer.address);

  // Print summary
  console.log("\n\n🎉 GenesisVault Diamond Deployment Summary");
  console.log("===========================================");
  console.log("Diamond Address:", diamondAddress);
  console.log("Network:", networkName);
  console.log("Owner:", deployer.address);
  console.log("===========================================");
  console.log("\n📋 Facets:");
  console.log("- DiamondCutFacet:", facets.diamondCutFacet);
  console.log("- DiamondLoupeFacet:", facets.diamondLoupeFacet);
  console.log("- ERC20Facet:", facets.erc20Facet);
  console.log("- GenesisVaultViewFacet:", facets.genesisVaultViewFacet);
  console.log("- GenesisVaultAdminFacet (includes fee management):", facets.genesisVaultAdminFacet);
  console.log("- KeeperFacet:", facets.keeperFacet);
  console.log("- VaultCoreFacet (includes ERC7540):", facets.vaultCoreFacet);
  console.log("- SettlementFacet:", facets.settlementFacet);
  console.log("- InitializationFacet:", facets.initializationFacet);
  console.log("===========================================");

  // Query vault state (with delay for state propagation)
  console.log("\n📊 Vault State:");
  console.log("⏳ Waiting for state to propagate...");
  await new Promise((resolve) => setTimeout(resolve, 3000));

  try {
    const vaultView = await ethers.getContractAt(
      "contracts/genesis-vault/facets/GenesisVaultViewFacet.sol:GenesisVaultViewFacet",
      diamondAddress,
    );
    const erc20Facet = await ethers.getContractAt(
      "contracts/genesis-vault/facets/ERC20Facet.sol:ERC20Facet",
      diamondAddress,
    );
    console.log("- Name:", await erc20Facet.name());
    console.log("- Symbol:", await erc20Facet.symbol());
    console.log("- Asset:", await vaultView.asset());
    console.log("- Owner:", await vaultView.owner());
    console.log("- Admin:", await vaultView.admin());
    console.log("- Management Fee:", ethers.formatEther(await vaultView.managementFee()), "%");
    console.log("- Performance Fee:", ethers.formatEther(await vaultView.performanceFee()), "%");
    console.log("- Total Supply:", ethers.formatEther(await erc20Facet.totalSupply()));
  } catch (error) {
    console.log("⚠️ Could not read vault state:", error);
  }

  console.log("\n🎉 Deployment completed successfully!");

  // Verify contracts on block explorer
  console.log("\n🔍 Verifying contracts on block explorer...");
  const networkInfo = await ethers.getDefaultProvider().getNetwork();

  try {
    // Verify Diamond
    console.log("\n📝 Verifying Diamond...");
    await run("verify:verify", {
      address: diamondAddress,
      network: networkInfo,
      contract: "contracts/diamond-common/Diamond.sol:Diamond",
      constructorArguments: [deployer.address, facets.diamondCutFacet],
    });
    console.log("✅ Diamond verified");
  } catch (error: any) {
    console.log("⚠️ Diamond verification failed:", error.message);
  }

  try {
    // Verify DiamondCutFacet
    console.log("\n📝 Verifying DiamondCutFacet...");
    await run("verify:verify", {
      address: facets.diamondCutFacet,
      network: networkInfo,
      contract: "contracts/diamond-common/facets/DiamondCutFacet.sol:DiamondCutFacet",
      constructorArguments: [],
    });
    console.log("✅ DiamondCutFacet verified");
  } catch (error: any) {
    console.log("⚠️ DiamondCutFacet verification failed:", error.message);
  }

  try {
    // Verify DiamondLoupeFacet
    console.log("\n📝 Verifying DiamondLoupeFacet...");
    await run("verify:verify", {
      address: facets.diamondLoupeFacet,
      network: networkInfo,
      contract: "contracts/diamond-common/facets/DiamondLoupeFacet.sol:DiamondLoupeFacet",
      constructorArguments: [],
    });
    console.log("✅ DiamondLoupeFacet verified");
  } catch (error: any) {
    console.log("⚠️ DiamondLoupeFacet verification failed:", error.message);
  }

  try {
    // Verify ERC20Facet
    console.log("\n📝 Verifying ERC20Facet...");
    await run("verify:verify", {
      address: facets.erc20Facet,
      network: networkInfo,
      contract: "contracts/genesis-vault/facets/ERC20Facet.sol:ERC20Facet",
      constructorArguments: [],
    });
    console.log("✅ ERC20Facet verified");
  } catch (error: any) {
    console.log("⚠️ ERC20Facet verification failed:", error.message);
  }

  try {
    // Verify GenesisVaultViewFacet
    console.log("\n📝 Verifying GenesisVaultViewFacet...");
    await run("verify:verify", {
      address: facets.genesisVaultViewFacet,
      network: networkInfo,
      contract: "contracts/genesis-vault/facets/GenesisVaultViewFacet.sol:GenesisVaultViewFacet",
      constructorArguments: [],
    });
    console.log("✅ GenesisVaultViewFacet verified");
  } catch (error: any) {
    console.log("⚠️ GenesisVaultViewFacet verification failed:", error.message);
  }

  try {
    // Verify GenesisVaultAdminFacet
    console.log("\n📝 Verifying GenesisVaultAdminFacet...");
    await run("verify:verify", {
      address: facets.genesisVaultAdminFacet,
      network: networkInfo,
      contract: "contracts/genesis-vault/facets/GenesisVaultAdminFacet.sol:GenesisVaultAdminFacet",
      constructorArguments: [],
    });
    console.log("✅ GenesisVaultAdminFacet verified");
  } catch (error: any) {
    console.log("⚠️ GenesisVaultAdminFacet verification failed:", error.message);
  }

  try {
    // Verify KeeperFacet
    console.log("\n📝 Verifying KeeperFacet...");
    await run("verify:verify", {
      address: facets.keeperFacet,
      network: networkInfo,
      contract: "contracts/genesis-vault/facets/KeeperFacet.sol:KeeperFacet",
      constructorArguments: [],
    });
    console.log("✅ KeeperFacet verified");
  } catch (error: any) {
    console.log("⚠️ KeeperFacet verification failed:", error.message);
  }

  try {
    // Verify VaultCoreFacet
    console.log("\n📝 Verifying VaultCoreFacet...");
    await run("verify:verify", {
      address: facets.vaultCoreFacet,
      network: networkInfo,
      contract: "contracts/genesis-vault/facets/VaultCoreFacet.sol:VaultCoreFacet",
      constructorArguments: [],
    });
    console.log("✅ VaultCoreFacet verified");
  } catch (error: any) {
    console.log("⚠️ VaultCoreFacet verification failed:", error.message);
  }

  try {
    // Verify SettlementFacet
    console.log("\n📝 Verifying SettlementFacet...");
    await run("verify:verify", {
      address: facets.settlementFacet,
      network: networkInfo,
      contract: "contracts/genesis-vault/facets/SettlementFacet.sol:SettlementFacet",
      constructorArguments: [],
    });
    console.log("✅ SettlementFacet verified");
  } catch (error: any) {
    console.log("⚠️ SettlementFacet verification failed:", error.message);
  }

  try {
    // Verify InitializationFacet
    console.log("\n📝 Verifying GenesisVaultInitializationFacet...");
    await run("verify:verify", {
      address: facets.initializationFacet,
      network: networkInfo,
      contract:
        "contracts/genesis-vault/facets/GenesisVaultInitializationFacet.sol:GenesisVaultInitializationFacet",
      constructorArguments: [],
    });
    console.log("✅ GenesisVaultInitializationFacet verified");
  } catch (error: any) {
    console.log("⚠️ GenesisVaultInitializationFacet verification failed:", error.message);
  }

  console.log("\n✅ Contract verification process completed!");
  console.log("Note: Some contracts may already be verified or may take time to be indexed.");
};

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
