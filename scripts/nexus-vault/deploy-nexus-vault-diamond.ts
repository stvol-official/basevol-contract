import { ethers, network, run } from "hardhat";
import config from "../../config";

/*
 * NexusVault Diamond Deployment Script
 *
 * Usage:
 *   npx hardhat run --network base_sepolia scripts/nexus-vault/deploy-nexus-vault-diamond.ts
 *   npx hardhat run --network base scripts/nexus-vault/deploy-nexus-vault-diamond.ts
 *
 * This script deploys the NexusVault Diamond with all facets and initializes
 * the vault with default configuration.
 */

const NETWORK = ["base_sepolia", "base", "hardhat", "localhost"] as const;
type SupportedNetwork = (typeof NETWORK)[number];

interface DeployedContracts {
  diamond: string;
  diamondCutFacet: string;
  diamondLoupeFacet: string;
  erc20Facet: string;
  nexusVaultViewFacet: string;
  nexusVaultAdminFacet: string;
  nexusVaultCoreFacet: string;
  nexusVaultRebalanceFacet: string;
  nexusVaultInitFacet: string;
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

  // Deploy ERC20Facet (NexusVault's ERC20 implementation)
  const ERC20Facet = await ethers.getContractFactory(
    "contracts/nexus-vault/facets/ERC20Facet.sol:ERC20Facet",
  );
  const erc20Facet = await ERC20Facet.deploy();
  await erc20Facet.waitForDeployment();
  const erc20FacetAddress = await erc20Facet.getAddress();
  console.log("✅ ERC20Facet deployed at:", erc20FacetAddress);

  // Deploy NexusVaultViewFacet
  const NexusVaultViewFacet = await ethers.getContractFactory(
    "contracts/nexus-vault/facets/NexusVaultViewFacet.sol:NexusVaultViewFacet",
  );
  const nexusVaultViewFacet = await NexusVaultViewFacet.deploy();
  await nexusVaultViewFacet.waitForDeployment();
  const nexusVaultViewFacetAddress = await nexusVaultViewFacet.getAddress();
  console.log("✅ NexusVaultViewFacet deployed at:", nexusVaultViewFacetAddress);

  // Deploy NexusVaultAdminFacet
  const NexusVaultAdminFacet = await ethers.getContractFactory(
    "contracts/nexus-vault/facets/NexusVaultAdminFacet.sol:NexusVaultAdminFacet",
  );
  const nexusVaultAdminFacet = await NexusVaultAdminFacet.deploy();
  await nexusVaultAdminFacet.waitForDeployment();
  const nexusVaultAdminFacetAddress = await nexusVaultAdminFacet.getAddress();
  console.log("✅ NexusVaultAdminFacet deployed at:", nexusVaultAdminFacetAddress);

  // Deploy NexusVaultCoreFacet
  const NexusVaultCoreFacet = await ethers.getContractFactory(
    "contracts/nexus-vault/facets/NexusVaultCoreFacet.sol:NexusVaultCoreFacet",
  );
  const nexusVaultCoreFacet = await NexusVaultCoreFacet.deploy();
  await nexusVaultCoreFacet.waitForDeployment();
  const nexusVaultCoreFacetAddress = await nexusVaultCoreFacet.getAddress();
  console.log("✅ NexusVaultCoreFacet deployed at:", nexusVaultCoreFacetAddress);

  // Deploy NexusVaultRebalanceFacet
  const NexusVaultRebalanceFacet = await ethers.getContractFactory(
    "contracts/nexus-vault/facets/NexusVaultRebalanceFacet.sol:NexusVaultRebalanceFacet",
  );
  const nexusVaultRebalanceFacet = await NexusVaultRebalanceFacet.deploy();
  await nexusVaultRebalanceFacet.waitForDeployment();
  const nexusVaultRebalanceFacetAddress = await nexusVaultRebalanceFacet.getAddress();
  console.log("✅ NexusVaultRebalanceFacet deployed at:", nexusVaultRebalanceFacetAddress);

  // Deploy NexusVaultInitFacet
  const NexusVaultInitFacet = await ethers.getContractFactory(
    "contracts/nexus-vault/facets/NexusVaultInitFacet.sol:NexusVaultInitFacet",
  );
  const nexusVaultInitFacet = await NexusVaultInitFacet.deploy();
  await nexusVaultInitFacet.waitForDeployment();
  const nexusVaultInitFacetAddress = await nexusVaultInitFacet.getAddress();
  console.log("✅ NexusVaultInitFacet deployed at:", nexusVaultInitFacetAddress);

  // Verify all facets have code (for non-local networks)
  if (network.name !== "hardhat" && network.name !== "localhost") {
    console.log("\n⏳ Verifying contract code availability...");

    const facetsToVerify = [
      { name: "DiamondCutFacet", address: diamondCutFacetAddress },
      { name: "DiamondLoupeFacet", address: diamondLoupeFacetAddress },
      { name: "ERC20Facet", address: erc20FacetAddress },
      { name: "NexusVaultViewFacet", address: nexusVaultViewFacetAddress },
      { name: "NexusVaultAdminFacet", address: nexusVaultAdminFacetAddress },
      { name: "NexusVaultCoreFacet", address: nexusVaultCoreFacetAddress },
      { name: "NexusVaultRebalanceFacet", address: nexusVaultRebalanceFacetAddress },
      { name: "NexusVaultInitFacet", address: nexusVaultInitFacetAddress },
    ];

    for (const facet of facetsToVerify) {
      const hasCode = await waitForContractCode(facet.address);
      if (!hasCode) {
        throw new Error(`${facet.name} code not available at ${facet.address}`);
      }
      console.log(`  ✅ ${facet.name} verified`);
    }

    console.log("✅ All facets verified on network");
  }

  return {
    diamondCutFacet: diamondCutFacetAddress,
    diamondLoupeFacet: diamondLoupeFacetAddress,
    erc20Facet: erc20FacetAddress,
    nexusVaultViewFacet: nexusVaultViewFacetAddress,
    nexusVaultAdminFacet: nexusVaultAdminFacetAddress,
    nexusVaultCoreFacet: nexusVaultCoreFacetAddress,
    nexusVaultRebalanceFacet: nexusVaultRebalanceFacetAddress,
    nexusVaultInitFacet: nexusVaultInitFacetAddress,
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
  console.log("\n💎 Deploying NexusVault Diamond...");

  // Use NexusVaultDiamond
  const Diamond = await ethers.getContractFactory(
    "contracts/nexus-vault/NexusVaultDiamond.sol:NexusVaultDiamond",
  );

  // Prepare initial facet cuts (DiamondCutFacet)
  const DiamondCutFacetFactory = await ethers.getContractFactory(
    "contracts/diamond-common/facets/DiamondCutFacet.sol:DiamondCutFacet",
  );
  const diamondCutSelectors = await getSelectors(DiamondCutFacetFactory.interface);

  const FacetCutAction = { Add: 0, Replace: 1, Remove: 2 };
  const initialCuts = [
    {
      facetAddress: facets.diamondCutFacet,
      action: FacetCutAction.Add,
      functionSelectors: diamondCutSelectors,
    },
  ];

  const diamond = await Diamond.deploy(owner, initialCuts);
  await diamond.waitForDeployment();
  const diamondAddress = await diamond.getAddress();
  console.log("✅ NexusVault Diamond deployed at:", diamondAddress);

  return diamondAddress;
}

async function addFacets(diamondAddress: string, facets: Omit<DeployedContracts, "diamond">) {
  console.log("\n🔧 Adding Facets to Diamond...");

  const diamondCut = await ethers.getContractAt(
    "contracts/diamond-common/interfaces/IDiamondCut.sol:IDiamondCut",
    diamondAddress,
  );

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
    "contracts/nexus-vault/facets/ERC20Facet.sol:ERC20Facet",
  );
  cuts.push({
    facetAddress: facets.erc20Facet,
    action: FacetCutAction.Add,
    functionSelectors: await getSelectors(ERC20FacetFactory.interface),
  });

  // NexusVaultViewFacet
  const NexusVaultViewFacetFactory = await ethers.getContractFactory(
    "contracts/nexus-vault/facets/NexusVaultViewFacet.sol:NexusVaultViewFacet",
  );
  // Exclude functions that overlap with ERC20Facet
  const viewExclude = [
    "0x06fdde03", // name()
    "0x95d89b41", // symbol()
    "0x313ce567", // decimals()
    "0x18160ddd", // totalSupply()
  ];
  cuts.push({
    facetAddress: facets.nexusVaultViewFacet,
    action: FacetCutAction.Add,
    functionSelectors: await getSelectors(NexusVaultViewFacetFactory.interface, viewExclude),
  });

  // NexusVaultAdminFacet
  const NexusVaultAdminFacetFactory = await ethers.getContractFactory(
    "contracts/nexus-vault/facets/NexusVaultAdminFacet.sol:NexusVaultAdminFacet",
  );
  cuts.push({
    facetAddress: facets.nexusVaultAdminFacet,
    action: FacetCutAction.Add,
    functionSelectors: await getSelectors(NexusVaultAdminFacetFactory.interface),
  });

  // NexusVaultCoreFacet
  const NexusVaultCoreFacetFactory = await ethers.getContractFactory(
    "contracts/nexus-vault/facets/NexusVaultCoreFacet.sol:NexusVaultCoreFacet",
  );
  cuts.push({
    facetAddress: facets.nexusVaultCoreFacet,
    action: FacetCutAction.Add,
    functionSelectors: await getSelectors(NexusVaultCoreFacetFactory.interface),
  });

  // NexusVaultRebalanceFacet
  const NexusVaultRebalanceFacetFactory = await ethers.getContractFactory(
    "contracts/nexus-vault/facets/NexusVaultRebalanceFacet.sol:NexusVaultRebalanceFacet",
  );
  cuts.push({
    facetAddress: facets.nexusVaultRebalanceFacet,
    action: FacetCutAction.Add,
    functionSelectors: await getSelectors(NexusVaultRebalanceFacetFactory.interface),
  });

  // NexusVaultInitFacet
  const NexusVaultInitFacetFactory = await ethers.getContractFactory(
    "contracts/nexus-vault/facets/NexusVaultInitFacet.sol:NexusVaultInitFacet",
  );
  cuts.push({
    facetAddress: facets.nexusVaultInitFacet,
    action: FacetCutAction.Add,
    functionSelectors: await getSelectors(NexusVaultInitFacetFactory.interface),
  });

  // Check for duplicate selectors
  console.log("\n🔍 Checking for duplicate selectors...");
  const selectorMap = new Map<string, string[]>();

  for (let i = 0; i < cuts.length; i++) {
    console.log(
      `  Facet ${i + 1}: ${cuts[i].facetAddress} with ${cuts[i].functionSelectors.length} selectors`,
    );

    for (const selector of cuts[i].functionSelectors) {
      if (!selectorMap.has(selector)) {
        selectorMap.set(selector, []);
      }
      selectorMap.get(selector)!.push(`Facet ${i + 1} (${cuts[i].facetAddress})`);
    }
  }

  let hasDuplicates = false;
  for (const [selector, facetList] of selectorMap.entries()) {
    if (facetList.length > 1) {
      console.error(`  ❌ Selector ${selector} appears in multiple facets:`);
      facetList.forEach((facet) => console.error(`     - ${facet}`));
      hasDuplicates = true;
    }
  }

  if (hasDuplicates) {
    throw new Error("Duplicate function selectors detected across facets!");
  }
  console.log("  ✅ No duplicate selectors found");

  // Execute diamond cut
  console.log("\n🔪 Executing diamondCut...");
  try {
    const gasEstimate = await diamondCut.diamondCut.estimateGas(cuts, ethers.ZeroAddress, "0x");
    console.log(`⛽ Estimated gas: ${gasEstimate.toString()}`);

    const tx = await diamondCut.diamondCut(cuts, ethers.ZeroAddress, "0x");
    console.log(`📝 Transaction hash: ${tx.hash}`);
    console.log("⏳ Waiting for transaction confirmation...");
    const receipt = await tx.wait();
    console.log(`✅ Transaction confirmed in block ${receipt?.blockNumber}`);
  } catch (error: any) {
    console.error("\n❌ DiamondCut failed!");
    console.error("Error message:", error.message);
    throw error;
  }

  console.log("✅ All facets added to Diamond");
}

async function initializeVault(
  diamondAddress: string,
  networkName: SupportedNetwork,
  owner: string,
) {
  console.log("\n🚀 Initializing NexusVault...");

  // Get USDC address based on network
  let usdcAddress: string;
  if (networkName === "hardhat" || networkName === "localhost") {
    // Deploy mock USDC for local testing
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const mockUsdc = await MockERC20.deploy("USD Coin", "USDC", 6);
    await mockUsdc.waitForDeployment();
    usdcAddress = await mockUsdc.getAddress();
    console.log("  📝 Mock USDC deployed at:", usdcAddress);
  } else {
    usdcAddress = config.Address.Usdc[networkName as "base_sepolia" | "base"];
  }

  const vault = await ethers.getContractAt(
    "contracts/nexus-vault/facets/NexusVaultInitFacet.sol:NexusVaultInitFacet",
    diamondAddress,
  );

  const initTx = await vault.initialize(
    usdcAddress, // asset
    "Nexus Vault", // name
    "nxVAULT", // symbol
    owner, // admin
    owner, // feeRecipient
  );
  await initTx.wait();

  console.log("✅ NexusVault initialized");

  // Verify initialization
  try {
    const erc20 = await ethers.getContractAt(
      "contracts/nexus-vault/facets/ERC20Facet.sol:ERC20Facet",
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

  console.log(`\n🌐 Deploying NexusVault to ${networkName} network...`);

  await run("compile");

  const [deployer] = await ethers.getSigners();

  console.log("\n===========================================");
  console.log("Owner: %s", deployer.address);
  if (networkName !== "hardhat" && networkName !== "localhost") {
    console.log("USDC: %s", config.Address.Usdc[networkName as "base_sepolia" | "base"]);
  }
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
  console.log("\n\n🎉 NexusVault Diamond Deployment Summary");
  console.log("===========================================");
  console.log("Diamond Address:", diamondAddress);
  console.log("Network:", networkName);
  console.log("Owner:", deployer.address);
  console.log("===========================================");
  console.log("\n📋 Facets:");
  console.log("- DiamondCutFacet:", facets.diamondCutFacet);
  console.log("- DiamondLoupeFacet:", facets.diamondLoupeFacet);
  console.log("- ERC20Facet:", facets.erc20Facet);
  console.log("- NexusVaultViewFacet:", facets.nexusVaultViewFacet);
  console.log("- NexusVaultAdminFacet:", facets.nexusVaultAdminFacet);
  console.log("- NexusVaultCoreFacet:", facets.nexusVaultCoreFacet);
  console.log("- NexusVaultRebalanceFacet:", facets.nexusVaultRebalanceFacet);
  console.log("- NexusVaultInitFacet:", facets.nexusVaultInitFacet);
  console.log("===========================================");

  // Query vault state
  console.log("\n📊 Vault State:");

  try {
    const vaultView = await ethers.getContractAt(
      "contracts/nexus-vault/facets/NexusVaultViewFacet.sol:NexusVaultViewFacet",
      diamondAddress,
    );
    const erc20Facet = await ethers.getContractAt(
      "contracts/nexus-vault/facets/ERC20Facet.sol:ERC20Facet",
      diamondAddress,
    );
    console.log("- Name:", await erc20Facet.name());
    console.log("- Symbol:", await erc20Facet.symbol());
    console.log("- Asset:", await vaultView.asset());
    console.log("- Owner:", await vaultView.owner());
    console.log("- Admin:", await vaultView.admin());
    console.log("- Paused:", await vaultView.paused());
    console.log("- Active Vaults:", (await vaultView.activeVaultCount()).toString());
  } catch (error) {
    console.log("⚠️ Could not read vault state:", error);
  }

  console.log("\n🎉 Deployment completed successfully!");

  // Return deployed addresses for testing
  return {
    diamond: diamondAddress,
    ...facets,
  };
};

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

export { main as deployNexusVault };
