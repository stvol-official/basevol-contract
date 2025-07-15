import fs from "fs";
import path from "path";

/*
 Diamond ABI integration generator

 Usage:
 npx ts-node scripts/generate-diamond-abi.ts
 or
 npx hardhat run scripts/generate-diamond-abi.ts
*/

interface ABIItem {
  type: string;
  name?: string;
  inputs?: any[];
  outputs?: any[];
  stateMutability?: string;
  anonymous?: boolean;
}

interface ContractABI {
  abi: ABIItem[];
}

const FACET_NAMES = [
  "DiamondLoupeFacet",
  "InitializationFacet",
  "RoundManagementFacet",
  "OrderProcessingFacet",
  "RedemptionFacet",
  "AdminFacet",
  "ViewFacet",
];

const ARTIFACTS_PATH = "./artifacts/contracts";
const OUTPUT_PATH = "./data/abi/diamond";

function loadFacetABI(facetName: string): ABIItem[] {
  const abiPath = path.join(ARTIFACTS_PATH, "facets", `${facetName}.sol`, `${facetName}.json`);

  if (!fs.existsSync(abiPath)) {
    console.warn(`⚠️  ABI file not found: ${abiPath}`);
    return [];
  }

  try {
    const contractData: ContractABI = JSON.parse(fs.readFileSync(abiPath, "utf8"));
    return contractData.abi;
  } catch (error) {
    console.error(`❌ Failed to load ABI for ${facetName}:`, error);
    return [];
  }
}

function mergeDiamondABI(): ABIItem[] {
  const combinedABI: ABIItem[] = [];
  const functionSignatures = new Set<string>();
  const eventNames = new Set<string>();
  const errorNames = new Set<string>();

  console.log("🔄 Merging Diamond facet ABIs...");

  for (const facetName of FACET_NAMES) {
    console.log(`📦 Loading ${facetName}...`);
    const facetABI = loadFacetABI(facetName);

    for (const item of facetABI) {
      let shouldInclude = false;
      let identifier = "";

      switch (item.type) {
        case "function":
          // Create function signature for deduplication
          const inputs = item.inputs?.map((input) => input.type).join(",") || "";
          identifier = `${item.name}(${inputs})`;

          if (!functionSignatures.has(identifier)) {
            functionSignatures.add(identifier);
            shouldInclude = true;
          }
          break;

        case "event":
          identifier = item.name || "";
          if (!eventNames.has(identifier)) {
            eventNames.add(identifier);
            shouldInclude = true;
          }
          break;

        case "error":
          identifier = item.name || "";
          if (!errorNames.has(identifier)) {
            errorNames.add(identifier);
            shouldInclude = true;
          }
          break;

        case "constructor":
        case "receive":
        case "fallback":
          // Skip constructors and special functions for Diamond
          shouldInclude = false;
          break;

        default:
          shouldInclude = true;
      }

      if (shouldInclude) {
        combinedABI.push(item);
      }
    }
  }

  // Sort ABI for better readability
  combinedABI.sort((a, b) => {
    if (a.type !== b.type) {
      const typeOrder = { function: 0, event: 1, error: 2 };
      return (
        (typeOrder[a.type as keyof typeof typeOrder] || 3) -
        (typeOrder[b.type as keyof typeof typeOrder] || 3)
      );
    }
    return (a.name || "").localeCompare(b.name || "");
  });

  console.log(`✅ Combined ABI created:`);
  console.log(`   - Functions: ${functionSignatures.size}`);
  console.log(`   - Events: ${eventNames.size}`);
  console.log(`   - Errors: ${errorNames.size}`);
  console.log(`   - Total items: ${combinedABI.length}`);

  return combinedABI;
}

function generateABIFiles(combinedABI: ABIItem[]) {
  // Create output directory
  if (!fs.existsSync(OUTPUT_PATH)) {
    fs.mkdirSync(OUTPUT_PATH, { recursive: true });
  }

  // 1. Generate complete ABI JSON
  const abiJsonPath = path.join(OUTPUT_PATH, "BaseVolDiamond.json");
  fs.writeFileSync(abiJsonPath, JSON.stringify(combinedABI, null, 2));
  console.log(`💎 Complete ABI saved: ${abiJsonPath}`);

  // 2. Generate TypeScript interface
  const tsInterfacePath = path.join(OUTPUT_PATH, "BaseVolDiamond.interface.ts");
  const tsContent = `// Auto-generated Diamond ABI interface
// Generated on: ${new Date().toISOString()}

export const BaseVolDiamondABI = ${JSON.stringify(combinedABI, null, 2)} as const;

export type BaseVolDiamondABI = typeof BaseVolDiamondABI;
`;
  fs.writeFileSync(tsInterfacePath, tsContent);
  console.log(`🔷 TypeScript interface saved: ${tsInterfacePath}`);

  // 3. Generate function selector mappings (for debugging)
  const functionSelectors: Record<string, string> = {};
  const functions = combinedABI.filter((item) => item.type === "function");

  for (const func of functions) {
    if (func.name) {
      const inputs = func.inputs?.map((input) => input.type).join(",") || "";
      const signature = `${func.name}(${inputs})`;
      // Note: Actual selector calculation requires ethers.js
      functionSelectors[signature] = func.name;
    }
  }

  const selectorsPath = path.join(OUTPUT_PATH, "function-selectors.json");
  fs.writeFileSync(selectorsPath, JSON.stringify(functionSelectors, null, 2));
  console.log(`📋 Function selectors saved: ${selectorsPath}`);

  // 4. Generate usage example
  const examplePath = path.join(OUTPUT_PATH, "usage-example.md");
  const exampleContent = `# BaseVol Diamond ABI Usage

## Installation

\`\`\`bash
npm install ethers
\`\`\`

## Basic Usage

\`\`\`typescript
import { ethers } from "ethers";
import { BaseVolDiamondABI } from "./BaseVolDiamond.interface";

// Connect to Diamond contract
const provider = new ethers.JsonRpcProvider("https://sepolia.base.org");
const diamondAddress = "0x18770FE5BdD5D4AE9Ee884a1F6fCA883A6F9cbeD"; // Update with your address
const contract = new ethers.Contract(diamondAddress, BaseVolDiamondABI, provider);

// Example function calls
async function examples() {
  // View functions
  const currentEpoch = await contract.currentEpoch();
  const commissionFee = await contract.commissionfee();
  const addresses = await contract.addresses();
  
  // With signer for write operations
  const signer = new ethers.Wallet("YOUR_PRIVATE_KEY", provider);
  const contractWithSigner = contract.connect(signer);
  
  // Write functions (requires signer)
  // const tx = await contractWithSigner.submitFilledOrders(...);
  // await tx.wait();
}
\`\`\`

## Available Functions

### Read Functions
${functions
  .filter((f) => f.stateMutability === "view" || f.stateMutability === "pure")
  .map((f) => `- \`${f.name}\``)
  .join("\n")}

### Write Functions  
${functions
  .filter((f) => f.stateMutability !== "view" && f.stateMutability !== "pure")
  .map((f) => `- \`${f.name}\``)
  .join("\n")}

## Events
${combinedABI
  .filter((item) => item.type === "event")
  .map((e) => `- \`${e.name}\``)
  .join("\n")}
`;

  fs.writeFileSync(examplePath, exampleContent);
  console.log(`📖 Usage example saved: ${examplePath}`);
}

async function main() {
  console.log("🚀 Generating Diamond ABI for frontend...");
  console.log("=====================================");

  try {
    const combinedABI = mergeDiamondABI();
    generateABIFiles(combinedABI);

    console.log("\n🎉 Diamond ABI generation completed!");
    console.log(`📁 Output directory: ${OUTPUT_PATH}`);
    console.log("\n📋 Generated files:");
    console.log("   - BaseVolDiamond.json (Complete ABI)");
    console.log("   - BaseVolDiamond.interface.ts (TypeScript interface)");
    console.log("   - function-selectors.json (Function mappings)");
    console.log("   - usage-example.md (Usage documentation)");
  } catch (error) {
    console.error("💥 Failed to generate Diamond ABI:", error);
    process.exit(1);
  }
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}
