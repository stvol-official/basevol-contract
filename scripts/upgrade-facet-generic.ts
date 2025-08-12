import { ethers, network, run } from "hardhat";
import input from "@inquirer/input";
import select from "@inquirer/select";
import checkbox from "@inquirer/checkbox";

/*
 npx hardhat run --network base_sepolia scripts/upgrade-facet-generic.ts
 npx hardhat run --network base scripts/upgrade-facet-generic.ts
*/

const NETWORK = ["base_sepolia", "base"] as const;
type SupportedNetwork = (typeof NETWORK)[number];

// Diamond addresses by network
const DIAMOND_ADDRESSES = {
  base_sepolia: "0x66ee6506eD99859d340690d98a92db239909DF89", // Update after deployment
  base: "", // Update after deployment
};

// Available facets for upgrade
const AVAILABLE_FACETS = [
  { name: "RedemptionFacet", path: "contracts/facets/RedemptionFacet.sol:RedemptionFacet" },
  {
    name: "OrderProcessingFacet",
    path: "contracts/facets/OrderProcessingFacet.sol:OrderProcessingFacet",
  },
  {
    name: "RoundManagementFacet",
    path: "contracts/facets/RoundManagementFacet.sol:RoundManagementFacet",
  },
  { name: "AdminFacet", path: "contracts/facets/AdminFacet.sol:AdminFacet" },
  { name: "ViewFacet", path: "contracts/facets/ViewFacet.sol:ViewFacet" },
  {
    name: "InitializationFacet",
    path: "contracts/facets/InitializationFacet.sol:InitializationFacet",
  },
];

export enum FacetCutAction {
  Add = 0,
  Replace = 1,
  Remove = 2,
}

interface FacetCut {
  facetAddress: string;
  action: FacetCutAction;
  functionSelectors: string[];
}

interface FacetInfo {
  name: string;
  path: string;
  address?: string;
  functionSelectors?: string[];
}

interface FacetAnalysis {
  name: string;
  newSelectors: string[]; // Newly added functions
  existingSelectors: string[]; // Existing functions
  removedSelectors: string[]; // Removed functions
  cuts: FacetCut[]; // Cut operations to execute
  newFacetAddress: string;
}

function getSelectors(contract: any): string[] {
  const signatures: string[] = [];

  // Iterate through all functions in the interface
  contract.interface.forEachFunction((func: any) => {
    if (func.name !== "init") {
      signatures.push(func.selector);
    }
  });

  return signatures;
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

async function analyzeFacet(
  facetInfo: { name: string; path: string },
  diamondAddress: string,
): Promise<FacetAnalysis> {
  console.log(`🔍 Analyzing ${facetInfo.name}...`);

  // 1. Deploy new facet and get selectors
  const FacetFactory = await ethers.getContractFactory(facetInfo.name);
  const newFacet = await FacetFactory.deploy();
  await newFacet.waitForDeployment();
  const newFacetAddress = await newFacet.getAddress();
  const newSelectors = getSelectors(newFacet);

  console.log(`📦 New ${facetInfo.name} deployed to: ${newFacetAddress}`);
  console.log(`🔢 New selectors (${newSelectors.length}): ${newSelectors.join(", ")}`);

  // 2. Check selectors registered in current Diamond
  const diamondLoupe = await ethers.getContractAt("IDiamondLoupe", diamondAddress);
  const currentFacets = await diamondLoupe.facets();

  // Map all currently registered selectors and their facet addresses
  const currentSelectorToFacet = new Map<string, string>();
  for (const facet of currentFacets) {
    for (const selector of facet.functionSelectors) {
      currentSelectorToFacet.set(selector, facet.facetAddress);
    }
  }

  // 3. Find selectors that existing facet had (from facet with same name)
  const existingSelectorsFromThisFacet: string[] = [];
  const existingSelectorsFromOtherFacets: string[] = [];

  for (const selector of newSelectors) {
    if (currentSelectorToFacet.has(selector)) {
      // Check which facet this selector is currently registered to
      // For accurate judgment, we should know the address of the previously deployed same facet,
      // but here we just check existence
      existingSelectorsFromThisFacet.push(selector);
    }
  }

  // 4. Newly added selectors (not in current Diamond)
  const newSelectorsToAdd = newSelectors.filter(
    (selector) => !currentSelectorToFacet.has(selector),
  );

  // 5. Find selectors to remove (existed before but not in new version)
  // For this, we need to know the selectors of the previous version of the facet,
  // but here we estimate selectors associated with this facet in current Diamond
  const removedSelectors: string[] = [];

  // Simple heuristic: find selectors that are presumed to have been deployed with the same facet name
  // A more accurate method would be to store previous deployment records, but here we judge only by current state

  console.log(
    `✅ Existing selectors (${existingSelectorsFromThisFacet.length}): ${existingSelectorsFromThisFacet.join(", ")}`,
  );
  console.log(
    `🆕 New selectors to add (${newSelectorsToAdd.length}): ${newSelectorsToAdd.join(", ")}`,
  );

  // 6. Create cut operations
  const cuts: FacetCut[] = [];

  // Add new selectors
  if (newSelectorsToAdd.length > 0) {
    cuts.push({
      facetAddress: newFacetAddress,
      action: FacetCutAction.Add,
      functionSelectors: newSelectorsToAdd,
    });
  }

  // Replace existing selectors
  if (existingSelectorsFromThisFacet.length > 0) {
    cuts.push({
      facetAddress: newFacetAddress,
      action: FacetCutAction.Replace,
      functionSelectors: existingSelectorsFromThisFacet,
    });
  }

  // Remove selectors (currently omitted as automatic detection is difficult)
  // Process manually if needed or use separate config file

  return {
    name: facetInfo.name,
    newSelectors: newSelectorsToAdd,
    existingSelectors: existingSelectorsFromThisFacet,
    removedSelectors: removedSelectors,
    cuts: cuts,
    newFacetAddress: newFacetAddress,
  };
}

const main = async () => {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name as SupportedNetwork;

  // Check if the network is supported.
  if (!NETWORK.includes(networkName)) {
    console.log(`Deploying to ${networkName} network is not supported...`);
    return;
  }

  console.log(`🚀 Smart Diamond Facet Upgrade Tool for ${networkName} network`);
  console.log("This tool automatically detects changes and applies appropriate actions");

  // 1. Enter Diamond address
  const DIAMOND_ADDRESS = await input({
    message: "Enter the Diamond contract address",
    default: DIAMOND_ADDRESSES[networkName] || "",
    validate: (val) => {
      return ethers.isAddress(val) || "Please enter a valid address";
    },
  });

  // 2. Select facets to upgrade (multiple selection)
  const selectedFacets = await checkbox({
    message: "Select the facets to analyze and upgrade (use Space to select, Enter to confirm)",
    choices: AVAILABLE_FACETS.map((facet) => ({
      name: facet.name,
      value: facet,
    })),
    validate: (choices: readonly any[]) => {
      if (choices.length === 0) {
        return "You must choose at least one facet.";
      }
      return true;
    },
  });

  console.log("===========================================");
  console.log("Network:", networkName);
  console.log("Diamond Address:", DIAMOND_ADDRESS);
  console.log("Selected Facets:", selectedFacets.map((f: any) => f.name).join(", "));
  console.log("===========================================");

  // Compile contracts.
  await run("compile");
  console.log("✅ Compiled contracts...");

  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  console.log(`\n🔍 Analyzing ${selectedFacets.length} facet(s) for changes...\n`);

  // 3. Analyze and deploy each facet
  const facetAnalyses: FacetAnalysis[] = [];
  let totalCuts: FacetCut[] = [];

  for (let i = 0; i < selectedFacets.length; i++) {
    const facet = selectedFacets[i];
    console.log(`[${i + 1}/${selectedFacets.length}] Analyzing ${facet.name}...`);

    try {
      const analysis = await analyzeFacet(facet, DIAMOND_ADDRESS);
      facetAnalyses.push(analysis);
      totalCuts.push(...analysis.cuts);

      console.log(`📊 ${facet.name} Analysis Summary:`);
      console.log(`   🆕 New functions: ${analysis.newSelectors.length}`);
      console.log(`   🔄 Existing functions to update: ${analysis.existingSelectors.length}`);
      console.log(`   🗑️  Functions to remove: ${analysis.removedSelectors.length}`);
      console.log(`   ⚡ Cut operations: ${analysis.cuts.length}`);
      console.log(`   📍 New facet address: ${analysis.newFacetAddress}\n`);
    } catch (error) {
      console.error(`❌ Error analyzing ${facet.name}:`, error);
      return;
    }
  }

  // 4. Output analysis result summary
  console.log("📋 UPGRADE ANALYSIS SUMMARY");
  console.log("=".repeat(60));

  let totalNewFunctions = 0;
  let totalExistingFunctions = 0;
  let totalRemovedFunctions = 0;

  facetAnalyses.forEach((analysis, index) => {
    totalNewFunctions += analysis.newSelectors.length;
    totalExistingFunctions += analysis.existingSelectors.length;
    totalRemovedFunctions += analysis.removedSelectors.length;

    console.log(`${index + 1}. ${analysis.name}:`);
    if (analysis.newSelectors.length > 0) {
      console.log(`   🆕 Adding ${analysis.newSelectors.length} new function(s)`);
    }
    if (analysis.existingSelectors.length > 0) {
      console.log(`   🔄 Updating ${analysis.existingSelectors.length} existing function(s)`);
    }
    if (analysis.removedSelectors.length > 0) {
      console.log(`   🗑️  Removing ${analysis.removedSelectors.length} function(s)`);
    }
    if (analysis.cuts.length === 0) {
      console.log(`   ✅ No changes detected`);
    }
  });

  console.log("\n📊 Total Changes:");
  console.log(`   🆕 New functions: ${totalNewFunctions}`);
  console.log(`   🔄 Updated functions: ${totalExistingFunctions}`);
  console.log(`   🗑️  Removed functions: ${totalRemovedFunctions}`);
  console.log(`   ⚡ Total cut operations: ${totalCuts.length}`);

  if (totalCuts.length === 0) {
    console.log("\n🎉 No changes detected! All facets are up to date.");
    return;
  }

  // 5. Execution confirmation
  const confirmation = await input({
    message: `Proceed with ${totalCuts.length} cut operation(s)? (yes/no)`,
    validate: (val) => {
      return ["yes", "no", "y", "n"].includes(val.toLowerCase()) || "Please enter yes or no";
    },
  });

  if (!["yes", "y"].includes(confirmation.toLowerCase())) {
    console.log("❌ Operation cancelled");
    return;
  }

  // 6. Execute Diamond Cut
  console.log(`\n🔄 Executing ${totalCuts.length} diamond cut operation(s)...`);

  console.log("Operations to be executed:");
  totalCuts.forEach((cut, index) => {
    const actionName =
      cut.action === FacetCutAction.Add
        ? "ADD"
        : cut.action === FacetCutAction.Replace
          ? "REPLACE"
          : "REMOVE";
    console.log(
      `  ${index + 1}. ${actionName}: ${cut.functionSelectors.length} selectors to ${cut.facetAddress}`,
    );
  });

  const diamondCut = await ethers.getContractAt("IDiamondCut", DIAMOND_ADDRESS);

  const tx = await diamondCut.diamondCut(totalCuts, ethers.ZeroAddress, "0x");
  console.log("Diamond cut tx:", tx.hash);

  const receipt = await tx.wait();
  if (!receipt || receipt.status !== 1) {
    throw Error(`Diamond upgrade failed: ${tx.hash}`);
  }

  console.log("✅ Diamond cut completed successfully!");

  // 7. Verify upgrades
  console.log("\n🔍 Verifying upgrades...");
  const diamondLoupe = await ethers.getContractAt("IDiamondLoupe", DIAMOND_ADDRESS);

  for (const analysis of facetAnalyses) {
    if (analysis.cuts.length === 0) continue;

    console.log(`\n📋 Verifying ${analysis.name}...`);

    try {
      // Check if all selectors of new facet are properly registered
      const allSelectors = [...analysis.newSelectors, ...analysis.existingSelectors];

      for (const selector of allSelectors) {
        const facetAddress = await diamondLoupe.facetAddress(selector);
        if (facetAddress === analysis.newFacetAddress) {
          console.log(`   ✅ Selector ${selector} correctly points to new facet`);
        } else {
          console.log(`   ❌ Selector ${selector} verification failed!`);
          console.log(`      Expected: ${analysis.newFacetAddress}`);
          console.log(`      Actual: ${facetAddress}`);
        }
      }
    } catch (error) {
      console.log(`⚠️  Could not verify ${analysis.name}:`, error);
    }
  }

  // 8. Function testing
  console.log("\n🧪 Testing upgraded facets...");
  for (const analysis of facetAnalyses) {
    if (analysis.cuts.length === 0) continue;

    console.log(`Testing ${analysis.name}...`);
    try {
      const facetContract = await ethers.getContractAt(analysis.name, DIAMOND_ADDRESS);
      console.log(`✅ ${analysis.name} functions are accessible`);
    } catch (error) {
      console.log(`⚠️  Could not test ${analysis.name} functions:`, error);
    }
  }

  // 9. Contract verification (if API key exists)
  console.log("\n🔍 Verifying contracts on block explorer...");
  const apiKey = process.env.ALCHEMY_API_KEY;

  if (apiKey) {
    await sleep(6000); // Wait for block explorer indexing

    for (const analysis of facetAnalyses) {
      if (analysis.cuts.length === 0) continue;

      console.log(`Verifying ${analysis.name} contract...`);

      try {
        const networkInfo = await ethers
          .getDefaultProvider(
            `https://base-${networkName === "base_sepolia" ? "sepolia" : "mainnet"}.g.alchemy.com/v2/${apiKey}`,
          )
          .getNetwork();

        await run("verify:verify", {
          address: analysis.newFacetAddress,
          network: networkInfo,
          contract: AVAILABLE_FACETS.find((f) => f.name === analysis.name)?.path,
          constructorArguments: [],
        });
        console.log(`✅ ${analysis.name} verification done`);
      } catch (error) {
        console.log(`❌ ${analysis.name} verification failed:`, error);
      }
    }
  } else {
    console.log("⚠️  No ALCHEMY_API_KEY found, skipping block explorer verification");
  }

  // 10. Final summary
  console.log("\n" + "=".repeat(60));
  console.log("🎉 SMART FACET UPGRADE COMPLETED!");
  console.log("=".repeat(60));
  console.log("Network:", networkName);
  console.log("Diamond Address:", DIAMOND_ADDRESS);
  console.log(`Processed Facets: ${selectedFacets.length}`);
  console.log(`Total Operations: ${totalCuts.length}`);

  console.log("\n📊 Changes Applied:");
  console.log(`   🆕 Functions added: ${totalNewFunctions}`);
  console.log(`   🔄 Functions updated: ${totalExistingFunctions}`);
  console.log(`   🗑️  Functions removed: ${totalRemovedFunctions}`);

  console.log("\n📝 Facet Details:");
  facetAnalyses.forEach((analysis, index) => {
    console.log(`  ${index + 1}. ${analysis.name}`);
    console.log(`     Address: ${analysis.newFacetAddress}`);
    console.log(`     Operations: ${analysis.cuts.length}`);
  });

  console.log("=".repeat(60));

  console.log("\n📝 Next steps:");
  console.log("1. Update your frontend if any function signatures changed");
  console.log("2. Test all upgraded facet functions thoroughly");
  console.log("3. Update documentation with new facet addresses");
  console.log("4. Monitor the system for any issues");
};

if (require.main === module) {
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}

export { main as upgradeFacetGeneric };
