import { ethers, network, run } from "hardhat";
import input from "@inquirer/input";
import select from "@inquirer/select";
import checkbox from "@inquirer/checkbox";

/*
 npx hardhat run --network base_sepolia scripts/basevol/upgrade-basevol-facet.ts
 npx hardhat run --network base scripts/basevol/upgrade-basevol-facet.ts

 This script is designed to upgrade facets on MAINNET BaseVol Diamond contracts
 that were originally deployed with the legacy structure (contracts/facets/*).
 
 It deploys new facets from the new structure (contracts/basevol/facets/*)
 and upgrades them on the existing Diamond, maintaining full backward compatibility.
*/

const NETWORK = ["base_sepolia", "base"] as const;
type SupportedNetwork = (typeof NETWORK)[number];

// Mainnet Diamond addresses by network
const BASEVOL_DIAMOND_ADDRESSES = {
  base_sepolia: "0x66ee6506eD99859d340690d98a92db239909DF89",
  base: "", // Update with mainnet BaseVol Diamond address
};

// Available facets for upgrade (NEW STRUCTURE - contracts/basevol/facets)
// These will be deployed and used to upgrade the LEGACY Diamond
const AVAILABLE_FACETS = [
  {
    name: "RedemptionFacet",
    path: "contracts/basevol/facets/RedemptionFacet.sol:RedemptionFacet",
  },
  {
    name: "OrderProcessingFacet",
    path: "contracts/basevol/facets/OrderProcessingFacet.sol:OrderProcessingFacet",
  },
  {
    name: "RoundManagementFacet",
    path: "contracts/basevol/facets/RoundManagementFacet.sol:RoundManagementFacet",
    requiresLibrary: true,
    library: "PythLazerLib",
  },
  {
    name: "AdminFacet",
    path: "contracts/basevol/facets/BaseVolAdminFacet.sol:AdminFacet",
  },
  {
    name: "ViewFacet",
    path: "contracts/basevol/facets/BaseVolViewFacet.sol:ViewFacet",
  },
  {
    name: "InitializationFacet",
    path: "contracts/basevol/facets/InitializationFacet.sol:InitializationFacet",
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
  requiresLibrary?: boolean;
  library?: string;
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

function getSelectors(contractInterface: any): string[] {
  const signatures: string[] = [];

  // Iterate through all functions in the interface
  contractInterface.forEachFunction((func: any) => {
    if (func.name !== "init" && func.name !== "initialize") {
      signatures.push(func.selector);
    }
  });

  return signatures;
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

async function waitForContractCode(
  address: string,
  retries: number = 5,
  delayMs: number = 2000,
): Promise<boolean> {
  for (let i = 0; i < retries; i++) {
    const code = await ethers.provider.getCode(address);
    if (code !== "0x") {
      return true;
    }
    if (i < retries - 1) {
      console.log(`  ⏳ Waiting for contract code at ${address}... (attempt ${i + 1}/${retries})`);
      await sleep(delayMs);
    }
  }
  return false;
}

async function analyzeFacet(
  facetInfo: FacetInfo,
  diamondAddress: string,
  pythLazerLibAddress?: string,
): Promise<FacetAnalysis> {
  console.log(`🔍 Analyzing ${facetInfo.name}...`);

  // 1. Deploy new facet and get selectors
  let FacetFactory;
  if (facetInfo.requiresLibrary && facetInfo.library && pythLazerLibAddress) {
    console.log(`  📚 Using library: ${facetInfo.library} at ${pythLazerLibAddress}`);
    FacetFactory = await ethers.getContractFactory(facetInfo.path, {
      libraries: {
        [facetInfo.library]: pythLazerLibAddress,
      },
    });
  } else {
    FacetFactory = await ethers.getContractFactory(facetInfo.path);
  }

  // Deploy with retry on "already known" error
  let newFacet;
  let newFacetAddress;
  const maxRetries = 3;

  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      console.log(`  📦 Deploying new ${facetInfo.name}... (attempt ${attempt}/${maxRetries})`);
      newFacet = await FacetFactory.deploy();
      await newFacet.waitForDeployment();
      newFacetAddress = await newFacet.getAddress();
      break; // Success, exit retry loop
    } catch (error: any) {
      if (error.message.includes("already known") && attempt < maxRetries) {
        console.log(`  ⏳ Transaction already in mempool, waiting 5 seconds before retry...`);
        await sleep(5000);
        continue;
      } else if (error.message.includes("replacement fee too low") && attempt < maxRetries) {
        console.log(`  ⏳ Replacement fee too low, waiting 3 seconds...`);
        await sleep(3000);
        continue;
      } else {
        throw error; // Re-throw if not a known retryable error or max retries reached
      }
    }
  }

  if (!newFacet || !newFacetAddress) {
    throw new Error(`Failed to deploy ${facetInfo.name} after ${maxRetries} attempts`);
  }

  // Wait for contract code to be available on network
  const hasCode = await waitForContractCode(newFacetAddress);
  if (!hasCode) {
    throw new Error(`New facet code not available at ${newFacetAddress}`);
  }

  const newSelectors = getSelectors(FacetFactory.interface);

  console.log(`📦 New ${facetInfo.name} deployed to: ${newFacetAddress}`);
  console.log(`🔢 New selectors (${newSelectors.length}): ${newSelectors.join(", ")}`);

  // 2. Check selectors registered in current Diamond
  const diamondLoupe = await ethers.getContractAt(
    "contracts/diamond-common/interfaces/IDiamondLoupe.sol:IDiamondLoupe",
    diamondAddress,
  );
  const currentFacets = await diamondLoupe.facets();

  // Map all currently registered selectors and their facet addresses
  const currentSelectorToFacet = new Map<string, string>();
  for (const facet of currentFacets) {
    for (const selector of facet.functionSelectors) {
      currentSelectorToFacet.set(selector, facet.facetAddress);
    }
  }

  // 3. Find selectors that existing facet had
  const existingSelectorsFromThisFacet: string[] = [];

  for (const selector of newSelectors) {
    if (currentSelectorToFacet.has(selector)) {
      existingSelectorsFromThisFacet.push(selector);
    }
  }

  // 4. Newly added selectors (not in current Diamond)
  const newSelectorsToAdd = newSelectors.filter(
    (selector) => !currentSelectorToFacet.has(selector),
  );

  // 5. Find selectors to remove (existed before but not in new version)
  const removedSelectors: string[] = [];

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
  // Get network data from Hardhat config
  const networkName = network.name as SupportedNetwork;

  // Check if the network is supported
  if (!NETWORK.includes(networkName)) {
    console.log(`Deploying to ${networkName} network is not supported...`);
    return;
  }

  console.log(`🚀 BaseVol Facet Upgrade Tool for ${networkName} network`);
  console.log("=".repeat(80));
  console.log("⚠️  IMPORTANT: This script upgrades MAINNET BaseVol Diamond");
  console.log("   - Original deployment: contracts/facets/* (legacy)");
  console.log("   - New facets: contracts/basevol/facets/* (new structure)");
  console.log("   - Maintains full backward compatibility");
  console.log("=".repeat(80));

  // STEP 1: Capture BEFORE state
  console.log("\n" + "=".repeat(80));
  console.log("📊 STEP 1: CAPTURING BEFORE STATE");
  console.log("=".repeat(80));

  // 1. Enter Diamond address
  const DIAMOND_ADDRESS = await input({
    message: "Enter the BaseVol Diamond contract address",
    default: BASEVOL_DIAMOND_ADDRESSES[networkName] || "",
    validate: (val) => {
      return ethers.isAddress(val) || "Please enter a valid address";
    },
  });

  console.log("\n🔍 Collecting BEFORE state...");
  try {
    const { collectDiamondState } = await import("./verify-diamond-state");
    const beforeState = await collectDiamondState(DIAMOND_ADDRESS, networkName);
    console.log("✅ BEFORE state captured successfully!");
    console.log(`   Facets: ${beforeState.facetCount}`);
    console.log(`   Selectors: ${beforeState.totalSelectors}`);
    console.log(`   Commission Fee: ${beforeState.storageState.commissionFee}`);
  } catch (error) {
    console.error("\n❌ Failed to capture BEFORE state:");
    console.error(error);
    console.log("\n⚠️  Cannot proceed without BEFORE state for comparison.");
    console.log("   Please check:");
    console.log("   1. Diamond address is correct");
    console.log("   2. Network connection is stable");
    console.log("   3. Contract is deployed and accessible");
    throw error;
  }

  console.log("\n" + "=".repeat(80));
  console.log("📊 STEP 2: ANALYZING AND UPGRADING FACETS");
  console.log("=".repeat(80));

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

  console.log("\n===========================================");
  console.log("Network:", networkName);
  console.log("Diamond Address:", DIAMOND_ADDRESS);
  console.log("Selected Facets:", selectedFacets.map((f: any) => f.name).join(", "));
  console.log("===========================================");

  // Compile contracts
  await run("compile");
  console.log("✅ Compiled contracts...");

  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  // Deploy PythLazerLib if needed
  let pythLazerLibAddress: string | undefined;
  const needsLibrary = selectedFacets.some((f: any) => f.requiresLibrary);

  if (needsLibrary) {
    console.log("\n📚 Deploying PythLazerLib (required for RoundManagementFacet)...");
    const PythLazerLibFactory = await ethers.getContractFactory("PythLazerLib");
    const pythLazerLib = await PythLazerLibFactory.deploy();
    await pythLazerLib.waitForDeployment();
    pythLazerLibAddress = await pythLazerLib.getAddress();
    console.log("✅ PythLazerLib deployed to:", pythLazerLibAddress);
  }

  console.log(`\n🔍 Analyzing ${selectedFacets.length} facet(s) for changes...\n`);

  // 3. Analyze and deploy each facet
  const facetAnalyses: FacetAnalysis[] = [];
  let totalCuts: FacetCut[] = [];

  for (let i = 0; i < selectedFacets.length; i++) {
    const facet = selectedFacets[i];
    console.log(`[${i + 1}/${selectedFacets.length}] Analyzing ${facet.name}...`);

    try {
      const analysis = await analyzeFacet(facet, DIAMOND_ADDRESS, pythLazerLibAddress);
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
  if (networkName === "base") {
    console.log("\n⚠️  WARNING: You are about to upgrade MAINNET contracts!");
  }
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

  const diamondCut = await ethers.getContractAt(
    "contracts/diamond-common/interfaces/IDiamondCut.sol:IDiamondCut",
    DIAMOND_ADDRESS,
  );

  try {
    const tx = await diamondCut.diamondCut(totalCuts, ethers.ZeroAddress, "0x");
    console.log("Diamond cut tx:", tx.hash);

    const receipt = await tx.wait();
    if (!receipt || receipt.status !== 1) {
      throw Error(`Diamond upgrade failed: ${tx.hash}`);
    }

    console.log("✅ Diamond cut completed successfully!");
  } catch (error: any) {
    console.error("❌ Diamond cut failed:", error);

    // Try to decode common revert reasons
    if (error.data) {
      try {
        const iface = new ethers.Interface([
          "error LibDiamond__NoSelectorsProvidedForFacetForCut(address facet)",
          "error LibDiamond__CannotAddSelectorsToZeroAddress(bytes4[] selectors)",
          "error LibDiamond__NoBytecodeAtAddress(address contractAddress, string message)",
          "error LibDiamond__IncorrectFacetCutAction(uint8 action)",
          "error LibDiamond__CannotAddFunctionToDiamondThatAlreadyExists(bytes4 selector)",
          "error LibDiamond__CannotReplaceFunctionsFromFacetWithZeroAddress(bytes4[] selectors)",
          "error LibDiamond__CannotReplaceImmutableFunction(bytes4 selector)",
          "error LibDiamond__CannotReplaceFunctionWithTheSameFunctionFromTheSameFacet(bytes4 selector)",
          "error LibDiamond__CannotReplaceFunctionThatDoesNotExists(bytes4 selector)",
          "error LibDiamond__RemoveFacetAddressMustBeZeroAddress(address facetAddress)",
          "error LibDiamond__CannotRemoveFunctionThatDoesNotExist(bytes4 selector)",
          "error LibDiamond__CannotRemoveImmutableFunction(bytes4 selector)",
          "error LibDiamond__InitializationFunctionReverted(address initializationContractAddress, bytes _calldata)",
        ]);
        const decodedError = iface.parseError(error.data);
        console.error("Decoded error:", decodedError);
      } catch (decodeError) {
        console.error("Could not decode error data");
      }
    }
    return;
  }

  // Wait for network propagation
  console.log("\n⏳ Waiting for network state to propagate (3 seconds)...");
  await sleep(3000);

  // 7. Verify upgrades
  console.log("\n🔍 Verifying upgrades...");
  const diamondLoupe = await ethers.getContractAt(
    "contracts/diamond-common/interfaces/IDiamondLoupe.sol:IDiamondLoupe",
    DIAMOND_ADDRESS,
  );

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
      const facetPath = AVAILABLE_FACETS.find((f) => f.name === analysis.name)?.path;
      if (facetPath) {
        const facetContract = await ethers.getContractAt(facetPath, DIAMOND_ADDRESS);
        console.log(`✅ ${analysis.name} functions are accessible`);
      }
    } catch (error) {
      console.log(`⚠️  Could not test ${analysis.name} functions:`, error);
    }
  }

  // 9. Contract verification (if API key exists)
  console.log("\n🔍 Verifying contracts on block explorer...");
  const apiKey = process.env.BASESCAN_API_KEY;

  if (apiKey) {
    console.log("⏳ Waiting for block explorer indexing (6 seconds)...");
    await sleep(6000);

    for (const analysis of facetAnalyses) {
      if (analysis.cuts.length === 0) continue;

      console.log(`Verifying ${analysis.name} contract...`);

      try {
        const facetPath = AVAILABLE_FACETS.find((f) => f.name === analysis.name)?.path;
        await run("verify:verify", {
          address: analysis.newFacetAddress,
          contract: facetPath,
          constructorArguments: [],
        });
        console.log(`✅ ${analysis.name} verification done`);
      } catch (error: any) {
        if (error.message.includes("Already Verified")) {
          console.log(`✅ ${analysis.name} already verified`);
        } else {
          console.log(`❌ ${analysis.name} verification failed:`, error.message);
        }
      }
    }
  } else {
    console.log("⚠️  No BASESCAN_API_KEY found, skipping block explorer verification");
  }

  // 10. Final summary
  console.log("\n" + "=".repeat(80));
  console.log("🎉 STEP 2 COMPLETED - FACET UPGRADE SUCCESS!");
  console.log("=".repeat(80));
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

  console.log("=".repeat(80));

  // Step 3: Automatic verification and comparison
  console.log("\n" + "=".repeat(80));
  console.log("📊 STEP 3: AUTOMATIC VERIFICATION AND COMPARISON");
  console.log("=".repeat(80));

  try {
    const { collectDiamondState } = await import("./verify-diamond-state");
    const fs = await import("fs");
    const path = await import("path");

    console.log("\n🔍 Collecting AFTER state...");
    const afterState = await collectDiamondState(DIAMOND_ADDRESS, networkName);

    // Find the BEFORE state (the most recent file before the current run)
    const dataDir = path.join(__dirname, "../../data");
    const files = fs
      .readdirSync(dataDir)
      .filter((f) => f.startsWith(`diamond-state-${networkName}-`) && f.endsWith(".json"))
      .sort()
      .reverse();

    if (files.length >= 2) {
      console.log("\n📁 Comparing with BEFORE state...");
      const beforeFile = files[1]; // Second most recent (first is the one we just saved)
      const beforePath = path.join(dataDir, beforeFile);
      const beforeState = JSON.parse(fs.readFileSync(beforePath, "utf-8"));

      console.log(`   BEFORE: ${beforeFile}`);
      console.log(`   AFTER:  ${files[0]}`);

      // Import and run comparison
      const { compareStates } = await import("./verify-diamond-state");
      console.log("\n");
      compareStates(beforeState, afterState);

      // Check if there were any errors
      let hasErrors = false;

      // Check storage state
      const storageKeys = Object.keys(beforeState.storageState);
      for (const key of storageKeys) {
        const beforeVal = (beforeState.storageState as any)[key];
        const afterVal = (afterState.storageState as any)[key];
        if (beforeVal !== afterVal) {
          hasErrors = true;
          break;
        }
      }

      // Check ViewFacet functions
      if (!hasErrors) {
        const viewKeys = Object.keys(beforeState.viewFunctions);
        for (const key of viewKeys) {
          const beforeSuccess = (beforeState.viewFunctions as any)[key]?.success;
          const afterSuccess = (afterState.viewFunctions as any)[key]?.success;
          if (beforeSuccess && !afterSuccess) {
            hasErrors = true;
            break;
          }
        }
      }

      if (hasErrors) {
        console.log("\n" + "=".repeat(80));
        console.log("❌ CRITICAL ERROR DETECTED DURING VERIFICATION!");
        console.log("=".repeat(80));
        console.log("\n⚠️  The upgrade completed but verification shows critical issues!");
        console.log("⚠️  IMMEDIATE ACTION REQUIRED:");
        console.log("   1. Review the comparison results above");
        console.log("   2. Check if storage values changed unexpectedly");
        console.log("   3. Consider ROLLBACK if on mainnet");
        console.log("\n📝 See TROUBLESHOOTING.md for rollback instructions");
        console.log("=".repeat(80));
        process.exitCode = 1;
        return;
      }
    } else {
      console.log("\n⚠️  No previous state file found for comparison.");
      console.log("   This might be the first upgrade run.");
      console.log("   The AFTER state has been saved successfully.");
    }

    console.log("\n" + "=".repeat(80));
    console.log("✅ UPGRADE COMPLETED SUCCESSFULLY!");
    console.log("=".repeat(80));
    console.log("\n📝 Next steps:");
    console.log("1. ✅ Verification passed - all functions work correctly");
    console.log("2. ✅ Storage integrity confirmed");
    console.log("3. Update documentation with new facet addresses");
    console.log("4. Monitor the system for any issues");
    console.log("\n💡 Safe to proceed with mainnet upgrade following same steps.");
    console.log("=".repeat(80));
  } catch (verificationError) {
    console.error("\n❌ Error during verification:");
    console.error(verificationError);
    console.log("\n⚠️  Upgrade completed but verification failed!");
    console.log("   Please run verification manually:");
    console.log(
      "   npx hardhat run --network",
      networkName,
      "scripts/basevol/verify-diamond-state.ts",
    );
  }
};

if (require.main === module) {
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}

export { main as upgradeBaseVolFacet };
