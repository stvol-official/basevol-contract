import { ethers, run } from "hardhat";

/*
 npx hardhat run scripts/basevol/verify-compatibility.ts

 This script verifies that the new basevol facets are compatible with the legacy facets
 by comparing their function selectors.
*/

interface FacetComparison {
  facetName: string;
  legacyPath: string;
  newPath: string;
  legacySelectors: string[];
  newSelectors: string[];
  matching: boolean;
  addedSelectors: string[];
  removedSelectors: string[];
}

function getSelectors(contractInterface: any): string[] {
  const signatures: string[] = [];

  contractInterface.forEachFunction((func: any) => {
    if (func.name !== "init" && func.name !== "initialize") {
      signatures.push(func.selector);
    }
  });

  return signatures.sort();
}

const FACET_COMPARISONS = [
  {
    facetName: "AdminFacet",
    legacyPath: "contracts/facets/AdminFacet.sol:AdminFacet",
    newPath: "contracts/basevol/facets/BaseVolAdminFacet.sol:AdminFacet",
  },
  {
    facetName: "ViewFacet",
    legacyPath: "contracts/facets/ViewFacet.sol:ViewFacet",
    newPath: "contracts/basevol/facets/BaseVolViewFacet.sol:ViewFacet",
  },
  {
    facetName: "OrderProcessingFacet",
    legacyPath: "contracts/facets/OrderProcessingFacet.sol:OrderProcessingFacet",
    newPath: "contracts/basevol/facets/OrderProcessingFacet.sol:OrderProcessingFacet",
  },
  {
    facetName: "RedemptionFacet",
    legacyPath: "contracts/facets/RedemptionFacet.sol:RedemptionFacet",
    newPath: "contracts/basevol/facets/RedemptionFacet.sol:RedemptionFacet",
  },
  {
    facetName: "RoundManagementFacet",
    legacyPath: "contracts/facets/RoundManagementFacet.sol:RoundManagementFacet",
    newPath: "contracts/basevol/facets/RoundManagementFacet.sol:RoundManagementFacet",
  },
  {
    facetName: "InitializationFacet",
    legacyPath: "contracts/facets/InitializationFacet.sol:InitializationFacet",
    newPath: "contracts/basevol/facets/InitializationFacet.sol:InitializationFacet",
  },
];

async function compareFacets(): Promise<FacetComparison[]> {
  console.log("🔍 Comparing Legacy vs New Facets\n");
  console.log("=".repeat(80));

  const results: FacetComparison[] = [];

  for (const comparison of FACET_COMPARISONS) {
    console.log(`📋 Analyzing ${comparison.facetName}...`);
    console.log("-".repeat(80));

    try {
      const legacyFactory = await ethers.getContractFactory(comparison.legacyPath);
      const legacySelectors = getSelectors(legacyFactory.interface);

      const newFactory = await ethers.getContractFactory(comparison.newPath);
      const newSelectors = getSelectors(newFactory.interface);

      // Compare selectors
      const addedSelectors = newSelectors.filter((s) => !legacySelectors.includes(s));
      const removedSelectors = legacySelectors.filter((s) => !newSelectors.includes(s));
      const matching = addedSelectors.length === 0 && removedSelectors.length === 0;

      console.log(`  Legacy selectors: ${legacySelectors.length}`);
      console.log(`  New selectors: ${newSelectors.length}`);

      if (matching) {
        console.log(`  ✅ COMPATIBLE - All selectors match!`);
      } else {
        console.log(`  ⚠️  DIFFERENCES DETECTED`);
        if (addedSelectors.length > 0) {
          console.log(`     🆕 Added (${addedSelectors.length}): ${addedSelectors.join(", ")}`);
          // Print function names for added selectors
          addedSelectors.forEach((selector) => {
            const func = newFactory.interface.getFunction(selector);
            console.log(
              `        - ${selector} = ${func?.name}(${func?.inputs.map((i) => i.type).join(", ")})`,
            );
          });
        }
        if (removedSelectors.length > 0) {
          console.log(
            `     🗑️  Removed (${removedSelectors.length}): ${removedSelectors.join(", ")}`,
          );
          // Print function names for removed selectors
          removedSelectors.forEach((selector) => {
            const func = legacyFactory.interface.getFunction(selector);
            console.log(
              `        - ${selector} = ${func?.name}(${func?.inputs.map((i) => i.type).join(", ")})`,
            );
          });
        }
      }

      results.push({
        facetName: comparison.facetName,
        legacyPath: comparison.legacyPath,
        newPath: comparison.newPath,
        legacySelectors,
        newSelectors,
        matching,
        addedSelectors,
        removedSelectors,
      });
    } catch (error) {
      console.log(`  ❌ Error comparing ${comparison.facetName}:`, error);
    }

    console.log();
  }

  return results;
}

async function main() {
  console.log("\n🚀 BaseVol Facet Compatibility Verification Tool");
  console.log("=".repeat(80));
  console.log("This tool compares legacy facets with new structure facets");
  console.log("to ensure they are fully compatible for mainnet upgrades.\n");

  // Compile contracts
  await run("compile");
  console.log("✅ Compiled contracts...\n");

  // Compare facets
  const results = await compareFacets();

  // Summary
  console.log("=".repeat(80));
  console.log("📊 COMPATIBILITY VERIFICATION SUMMARY");
  console.log("=".repeat(80));

  let allCompatible = true;
  let totalAdded = 0;
  let totalRemoved = 0;

  results.forEach((result, index) => {
    console.log(`${index + 1}. ${result.facetName}:`);
    if (result.matching) {
      console.log(`   ✅ Fully compatible - ${result.legacySelectors.length} functions`);
    } else {
      allCompatible = false;
      console.log(`   ⚠️  Differences found:`);
      console.log(`      Legacy: ${result.legacySelectors.length} functions`);
      console.log(`      New: ${result.newSelectors.length} functions`);
      if (result.addedSelectors.length > 0) {
        console.log(`      🆕 Added: ${result.addedSelectors.length} functions`);
        totalAdded += result.addedSelectors.length;
      }
      if (result.removedSelectors.length > 0) {
        console.log(`      🗑️  Removed: ${result.removedSelectors.length} functions`);
        totalRemoved += result.removedSelectors.length;
      }
    }
    console.log();
  });

  console.log("=".repeat(80));

  if (allCompatible) {
    console.log("🎉 SUCCESS: All facets are fully compatible!");
    console.log("   You can safely upgrade mainnet facets with the new structure.");
  } else {
    console.log("⚠️  ATTENTION: Some facets have differences");
    console.log(`   Total functions added: ${totalAdded}`);
    console.log(`   Total functions removed: ${totalRemoved}`);
    console.log();
    console.log("   This is OK if:");
    console.log("   - Added functions are intentional new features");
    console.log("   - Removed functions are intentional deprecations");
    console.log();
    console.log("   ⚠️  WARNING if:");
    console.log("   - Functions were removed unintentionally");
    console.log("   - Function signatures changed (creates new selector)");
  }

  console.log("\n📝 Notes:");
  console.log("   - Legacy path: contracts/facets/*");
  console.log("   - New path: contracts/basevol/facets/*");
  console.log("   - Only import paths differ, logic should be identical");
  console.log("   - Function selectors must match for compatibility");

  console.log("\n📚 Reference:");
  console.log("   - See scripts/basevol/README.md for upgrade procedures");
  console.log("   - Use scripts/basevol/upgrade-basevol-facet.ts for mainnet upgrades");

  console.log("\n" + "=".repeat(80));
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}

export { main as verifyCompatibility };
