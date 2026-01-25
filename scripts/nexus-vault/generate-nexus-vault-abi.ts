import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/*
 * NexusVault Diamond ABI Generator
 *
 * Usage:
 *   npx hardhat run scripts/nexus-vault/generate-nexus-vault-abi.ts
 *
 * Generates a combined ABI for the NexusVault Diamond from all facets
 * and outputs it to data/abi/nexus-vault/NexusVaultDiamond.json
 */

const FACET_CONTRACTS = [
  "contracts/diamond-common/facets/DiamondCutFacet.sol:DiamondCutFacet",
  "contracts/diamond-common/facets/DiamondLoupeFacet.sol:DiamondLoupeFacet",
  "contracts/nexus-vault/facets/ERC20Facet.sol:ERC20Facet",
  "contracts/nexus-vault/facets/NexusVaultViewFacet.sol:NexusVaultViewFacet",
  "contracts/nexus-vault/facets/NexusVaultAdminFacet.sol:NexusVaultAdminFacet",
  "contracts/nexus-vault/facets/NexusVaultCoreFacet.sol:NexusVaultCoreFacet",
  "contracts/nexus-vault/facets/NexusVaultRebalanceFacet.sol:NexusVaultRebalanceFacet",
  "contracts/nexus-vault/facets/NexusVaultInitFacet.sol:NexusVaultInitFacet",
];

// Selectors to exclude (duplicates between facets)
const EXCLUDE_SELECTORS = new Set([
  // From ViewFacet that overlap with ERC20Facet
  // name(), symbol(), decimals(), totalSupply() are in ERC20Facet
]);

interface AbiItem {
  type: string;
  name?: string;
  inputs?: any[];
  outputs?: any[];
  stateMutability?: string;
  anonymous?: boolean;
}

async function main() {
  console.log("🔧 Generating NexusVault Diamond ABI...\n");

  const combinedAbi: AbiItem[] = [];
  const seenSignatures = new Set<string>();
  const seenEvents = new Set<string>();

  for (const contractPath of FACET_CONTRACTS) {
    const facetName = contractPath.split(":")[1];
    console.log(`📦 Processing ${facetName}...`);

    try {
      const factory = await ethers.getContractFactory(contractPath);
      const abi = JSON.parse(factory.interface.formatJson());

      let added = 0;
      let skipped = 0;

      for (const item of abi) {
        if (item.type === "function") {
          // Create signature for deduplication
          const signature = `${item.name}(${(item.inputs || []).map((i: any) => i.type).join(",")})`;

          if (seenSignatures.has(signature)) {
            skipped++;
            continue;
          }

          seenSignatures.add(signature);
          combinedAbi.push(item);
          added++;
        } else if (item.type === "event") {
          const eventSig = `${item.name}(${(item.inputs || []).map((i: any) => i.type).join(",")})`;

          if (seenEvents.has(eventSig)) {
            skipped++;
            continue;
          }

          seenEvents.add(eventSig);
          combinedAbi.push(item);
          added++;
        } else if (item.type === "error") {
          // Include all errors
          const errorSig = `${item.name}(${(item.inputs || []).map((i: any) => i.type).join(",")})`;

          if (!seenSignatures.has(errorSig)) {
            seenSignatures.add(errorSig);
            combinedAbi.push(item);
            added++;
          } else {
            skipped++;
          }
        } else if (item.type === "constructor" || item.type === "fallback" || item.type === "receive") {
          // Skip constructor, fallback, receive as they're on the Diamond itself
          skipped++;
        }
      }

      console.log(`   Added: ${added}, Skipped: ${skipped}`);
    } catch (error: any) {
      console.log(`   ⚠️ Could not process: ${error.message}`);
    }
  }

  // Sort ABI by type and name
  combinedAbi.sort((a, b) => {
    const typeOrder: Record<string, number> = {
      function: 0,
      event: 1,
      error: 2,
    };
    const typeA = typeOrder[a.type] ?? 3;
    const typeB = typeOrder[b.type] ?? 3;

    if (typeA !== typeB) return typeA - typeB;
    return (a.name || "").localeCompare(b.name || "");
  });

  // Create output directory
  const outputDir = path.join(process.cwd(), "data", "abi", "nexus-vault");
  if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
  }

  // Write ABI JSON
  const abiPath = path.join(outputDir, "NexusVaultDiamond.json");
  fs.writeFileSync(abiPath, JSON.stringify(combinedAbi, null, 2));
  console.log(`\n✅ ABI written to: ${abiPath}`);

  // Generate TypeScript interface
  const tsInterface = generateTypeScriptInterface(combinedAbi);
  const tsPath = path.join(outputDir, "NexusVaultDiamond.interface.ts");
  fs.writeFileSync(tsPath, tsInterface);
  console.log(`✅ TypeScript interface written to: ${tsPath}`);

  // Print summary
  const functions = combinedAbi.filter((i) => i.type === "function");
  const events = combinedAbi.filter((i) => i.type === "event");
  const errors = combinedAbi.filter((i) => i.type === "error");

  console.log("\n===========================================");
  console.log("ABI Generation Summary");
  console.log("===========================================");
  console.log(`Functions: ${functions.length}`);
  console.log(`Events: ${events.length}`);
  console.log(`Errors: ${errors.length}`);
  console.log(`Total: ${combinedAbi.length}`);
  console.log("===========================================");
}

function generateTypeScriptInterface(abi: AbiItem[]): string {
  const lines: string[] = [
    "// Auto-generated NexusVault Diamond Interface",
    "// Generated at: " + new Date().toISOString(),
    "",
    "export const NexusVaultDiamondABI = ",
    JSON.stringify(abi, null, 2),
    " as const;",
    "",
    "export type NexusVaultDiamondABI = typeof NexusVaultDiamondABI;",
    "",
  ];

  return lines.join("\n");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
