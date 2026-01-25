import { ethers, network, run } from "hardhat";

/*
 * NexusVault Facet Upgrade Script
 *
 * Usage:
 *   npx hardhat run --network base_sepolia scripts/nexus-vault/upgrade-nexus-vault-facet.ts
 *   npx hardhat run --network base scripts/nexus-vault/upgrade-nexus-vault-facet.ts
 *
 * This script upgrades a specific facet in the NexusVault Diamond.
 * Update DIAMOND_ADDRESS and FACET_TO_UPGRADE before running.
 */

// ============ CONFIGURATION ============
// Update these values before running

const DIAMOND_ADDRESS = "0x..."; // NexusVault Diamond address

// Facet to upgrade - uncomment the one you want to upgrade
const FACET_TO_UPGRADE = "NexusVaultCoreFacet";
// const FACET_TO_UPGRADE = "NexusVaultViewFacet";
// const FACET_TO_UPGRADE = "NexusVaultAdminFacet";
// const FACET_TO_UPGRADE = "NexusVaultRebalanceFacet";
// const FACET_TO_UPGRADE = "ERC20Facet";

// =======================================

const FACET_CONTRACTS: Record<string, string> = {
  NexusVaultCoreFacet:
    "contracts/nexus-vault/facets/NexusVaultCoreFacet.sol:NexusVaultCoreFacet",
  NexusVaultViewFacet:
    "contracts/nexus-vault/facets/NexusVaultViewFacet.sol:NexusVaultViewFacet",
  NexusVaultAdminFacet:
    "contracts/nexus-vault/facets/NexusVaultAdminFacet.sol:NexusVaultAdminFacet",
  NexusVaultRebalanceFacet:
    "contracts/nexus-vault/facets/NexusVaultRebalanceFacet.sol:NexusVaultRebalanceFacet",
  ERC20Facet: "contracts/nexus-vault/facets/ERC20Facet.sol:ERC20Facet",
};

async function getSelectors(contractInterface: any, excludeSelectors: string[] = []) {
  const fragments = Object.values(contractInterface.fragments);
  const selectors = fragments
    .filter((fragment: any) => fragment.type === "function")
    .map((fragment: any) => fragment.selector)
    .filter((selector: string) => selector !== undefined)
    .filter((selector: string) => !excludeSelectors.includes(selector));

  return selectors;
}

async function main() {
  const networkName = network.name;
  console.log(`\n🔧 Upgrading ${FACET_TO_UPGRADE} on ${networkName}...`);

  if (DIAMOND_ADDRESS === "0x...") {
    throw new Error("Please set DIAMOND_ADDRESS before running this script");
  }

  await run("compile");

  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  // Get the facet contract path
  const facetContractPath = FACET_CONTRACTS[FACET_TO_UPGRADE];
  if (!facetContractPath) {
    throw new Error(`Unknown facet: ${FACET_TO_UPGRADE}`);
  }

  // Deploy new facet
  console.log(`\n📦 Deploying new ${FACET_TO_UPGRADE}...`);
  const FacetFactory = await ethers.getContractFactory(facetContractPath);
  const newFacet = await FacetFactory.deploy();
  await newFacet.waitForDeployment();
  const newFacetAddress = await newFacet.getAddress();
  console.log(`✅ New ${FACET_TO_UPGRADE} deployed at:`, newFacetAddress);

  // Get current facet address from Diamond
  const diamondLoupe = await ethers.getContractAt(
    "contracts/diamond-common/facets/DiamondLoupeFacet.sol:DiamondLoupeFacet",
    DIAMOND_ADDRESS,
  );

  // Get selectors
  const selectors = await getSelectors(FacetFactory.interface);
  console.log(`\n🔍 Found ${selectors.length} selectors to replace`);

  // Check current facet address for first selector
  const currentFacetAddress = await diamondLoupe.facetAddress(selectors[0]);
  console.log(`📍 Current facet address for ${FACET_TO_UPGRADE}:`, currentFacetAddress);

  // Prepare diamond cut
  const FacetCutAction = { Add: 0, Replace: 1, Remove: 2 };

  const cuts = [
    {
      facetAddress: newFacetAddress,
      action: FacetCutAction.Replace,
      functionSelectors: selectors,
    },
  ];

  // Execute diamond cut
  console.log("\n🔪 Executing diamondCut (Replace)...");
  const diamondCut = await ethers.getContractAt(
    "contracts/diamond-common/interfaces/IDiamondCut.sol:IDiamondCut",
    DIAMOND_ADDRESS,
  );

  try {
    const gasEstimate = await diamondCut.diamondCut.estimateGas(cuts, ethers.ZeroAddress, "0x");
    console.log(`⛽ Estimated gas: ${gasEstimate.toString()}`);

    const tx = await diamondCut.diamondCut(cuts, ethers.ZeroAddress, "0x");
    console.log(`📝 Transaction hash: ${tx.hash}`);
    const receipt = await tx.wait();
    console.log(`✅ Upgrade confirmed in block ${receipt?.blockNumber}`);
  } catch (error: any) {
    console.error("\n❌ DiamondCut failed!");
    console.error("Error:", error.message);
    throw error;
  }

  // Verify upgrade
  console.log("\n🔍 Verifying upgrade...");
  const newAddress = await diamondLoupe.facetAddress(selectors[0]);
  if (newAddress.toLowerCase() === newFacetAddress.toLowerCase()) {
    console.log("✅ Upgrade verified successfully!");
  } else {
    console.error("❌ Upgrade verification failed!");
    console.error(`Expected: ${newFacetAddress}`);
    console.error(`Got: ${newAddress}`);
  }

  console.log("\n===========================================");
  console.log("Upgrade Summary");
  console.log("===========================================");
  console.log("Diamond:", DIAMOND_ADDRESS);
  console.log("Facet:", FACET_TO_UPGRADE);
  console.log("Old Address:", currentFacetAddress);
  console.log("New Address:", newFacetAddress);
  console.log("Selectors Updated:", selectors.length);
  console.log("===========================================");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
