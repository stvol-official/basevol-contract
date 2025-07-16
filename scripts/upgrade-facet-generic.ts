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
  base_sepolia: "0x1Fc3D6502BdF2B52a4d0d61dcB2E119A46baf3d7", // Update after deployment
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

const main = async () => {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name as SupportedNetwork;

  // Check if the network is supported.
  if (!NETWORK.includes(networkName)) {
    console.log(`Deploying to ${networkName} network is not supported...`);
    return;
  }

  console.log(`🔄 Diamond Multi-Facet Upgrade Tool for ${networkName} network`);

  // 1. Diamond 주소 입력
  const DIAMOND_ADDRESS = await input({
    message: "Enter the Diamond contract address",
    default: DIAMOND_ADDRESSES[networkName] || "",
    validate: (val) => {
      return ethers.isAddress(val) || "Please enter a valid address";
    },
  });

  // 2. Select facets to upgrade (multiple selection)
  const selectedFacets = await checkbox({
    message: "Select the facets to upgrade (use Space to select, Enter to confirm)",
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

  // 3. Select action type (applied to all selected facets)
  const actionType = await select({
    message: "Select the upgrade action (will be applied to all selected facets)",
    choices: [
      { name: "Replace (Upgrade)", value: FacetCutAction.Replace },
      { name: "Add (New)", value: FacetCutAction.Add },
      { name: "Remove (Delete)", value: FacetCutAction.Remove },
    ],
  });

  console.log("===========================================");
  console.log("Network:", networkName);
  console.log("Diamond Address:", DIAMOND_ADDRESS);
  console.log("Selected Facets:", selectedFacets.map((f: any) => f.name).join(", "));
  console.log(
    "Action:",
    actionType === FacetCutAction.Replace
      ? "Replace"
      : actionType === FacetCutAction.Add
        ? "Add"
        : "Remove",
  );
  console.log("===========================================");

  // Confirmation request
  const confirmation = await input({
    message: `Do you want to proceed with ${actionType === FacetCutAction.Replace ? "upgrading" : actionType === FacetCutAction.Add ? "adding" : "removing"} ${selectedFacets.length} facet(s)? (yes/no)`,
    validate: (val) => {
      return ["yes", "no", "y", "n"].includes(val.toLowerCase()) || "Please enter yes or no";
    },
  });

  if (!["yes", "y"].includes(confirmation.toLowerCase())) {
    console.log("❌ Operation cancelled");
    return;
  }

  // Compile contracts.
  await run("compile");
  console.log("✅ Compiled contracts...");

  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const deployedFacets: FacetInfo[] = [];
  const cuts: FacetCut[] = [];

  console.log(`\n📦 Processing ${selectedFacets.length} facet(s)...\n`);

  // 4. Deploy new facets or get selectors for removal
  for (let i = 0; i < selectedFacets.length; i++) {
    const facet = selectedFacets[i];
    console.log(`[${i + 1}/${selectedFacets.length}] Processing ${facet.name}...`);

    let facetAddress = "";
    let functionSelectors: string[] = [];

    if (actionType !== FacetCutAction.Remove) {
      console.log(`📦 Deploying new ${facet.name}...`);
      const FacetFactory = await ethers.getContractFactory(facet.name);
      const newFacet = await FacetFactory.deploy();
      await newFacet.waitForDeployment();
      facetAddress = await newFacet.getAddress();
      console.log(`✅ ${facet.name} deployed to: ${facetAddress}`);

      // Get function selectors
      functionSelectors = getSelectors(newFacet);
      console.log(`🔍 Function selectors count: ${functionSelectors.length}`);
    } else {
      // For removal, get selectors from existing facet
      console.log(`🔍 Getting existing function selectors for ${facet.name}...`);
      const existingFacet = await ethers.getContractFactory(facet.name);
      functionSelectors = getSelectors(existingFacet);
      facetAddress = ethers.ZeroAddress; // Use ZeroAddress for removal
      console.log(`🔍 Function selectors count for removal: ${functionSelectors.length}`);
    }

    // Store deployed facet info
    deployedFacets.push({
      ...facet,
      address: facetAddress,
      functionSelectors: functionSelectors,
    });

    // Prepare cut for this facet
    cuts.push({
      facetAddress: facetAddress,
      action: actionType,
      functionSelectors: functionSelectors,
    });

    console.log(`✅ ${facet.name} processed successfully\n`);
  }

  // 5. Execute Diamond Cut for all facets in one transaction
  console.log(`🔄 Executing diamond cut for ${selectedFacets.length} facet(s)...`);
  console.log("Cuts to be executed:");
  cuts.forEach((cut, index) => {
    console.log(
      `  ${index + 1}. ${selectedFacets[index].name}: ${cut.functionSelectors.length} selectors`,
    );
  });

  const diamondCut = await ethers.getContractAt("IDiamondCut", DIAMOND_ADDRESS);

  const tx = await diamondCut.diamondCut(cuts, ethers.ZeroAddress, "0x");
  console.log("Diamond cut tx:", tx.hash);

  const receipt = await tx.wait();
  if (!receipt || receipt.status !== 1) {
    throw Error(`Diamond upgrade failed: ${tx.hash}`);
  }

  console.log("✅ Diamond cut completed successfully for all facets!");

  // 6. Verify upgrades
  if (actionType !== FacetCutAction.Remove) {
    console.log("\n🔍 Verifying upgrades...");
    const diamondLoupe = await ethers.getContractAt("IDiamondLoupe", DIAMOND_ADDRESS);

    for (let i = 0; i < deployedFacets.length; i++) {
      const facet = deployedFacets[i];
      console.log(`\n[${i + 1}/${deployedFacets.length}] Verifying ${facet.name}...`);

      try {
        if (facet.functionSelectors && facet.functionSelectors.length > 0) {
          const facetAddress = await diamondLoupe.facetAddress(facet.functionSelectors[0]);

          if (facetAddress === facet.address) {
            console.log(`✅ ${facet.name} verification successful!`);
            console.log(`   Address: ${facet.address}`);
          } else {
            console.log(`❌ ${facet.name} verification failed!`);
            console.log(`   Expected: ${facet.address}`);
            console.log(`   Actual: ${facetAddress}`);
          }
        }
      } catch (error) {
        console.log(`⚠️  Could not verify ${facet.name}:`, error);
      }
    }

    // 7. Function testing
    console.log("\n🧪 Testing upgraded facets...");
    for (let i = 0; i < deployedFacets.length; i++) {
      const facet = deployedFacets[i];
      console.log(`[${i + 1}/${deployedFacets.length}] Testing ${facet.name}...`);

      try {
        const facetContract = await ethers.getContractAt(facet.name, DIAMOND_ADDRESS);
        console.log(`✅ ${facet.name} functions are accessible`);
      } catch (error) {
        console.log(`⚠️  Could not test ${facet.name} functions:`, error);
      }
    }

    // 8. Contract verification (if API key available)
    console.log("\n🔍 Verifying contracts on block explorer...");
    const apiKey = process.env.ALCHEMY_API_KEY;

    if (apiKey) {
      await sleep(6000); // Wait for block explorer indexing

      for (let i = 0; i < deployedFacets.length; i++) {
        const facet = deployedFacets[i];
        console.log(`[${i + 1}/${deployedFacets.length}] Verifying ${facet.name} contract...`);

        try {
          const networkInfo = await ethers
            .getDefaultProvider(
              `https://base-${networkName === "base_sepolia" ? "sepolia" : "mainnet"}.g.alchemy.com/v2/${apiKey}`,
            )
            .getNetwork();

          await run("verify:verify", {
            address: facet.address,
            network: networkInfo,
            contract: facet.path,
            constructorArguments: [],
          });
          console.log(`✅ ${facet.name} verification done`);
        } catch (error) {
          console.log(`❌ ${facet.name} verification failed:`, error);
        }
      }
    } else {
      console.log("⚠️  No ALCHEMY_API_KEY found, skipping block explorer verification");
    }
  }

  // 9. Summary
  console.log("\n" + "=".repeat(60));
  console.log("🎉 MULTI-FACET UPGRADE COMPLETED!");
  console.log("=".repeat(60));
  console.log("Network:", networkName);
  console.log("Diamond Address:", DIAMOND_ADDRESS);
  console.log(
    `Action: ${actionType === FacetCutAction.Replace ? "Replace" : actionType === FacetCutAction.Add ? "Add" : "Remove"}`,
  );
  console.log(`Processed Facets: ${selectedFacets.length}`);
  console.log("\nFacet Details:");

  deployedFacets.forEach((facet, index) => {
    console.log(`  ${index + 1}. ${facet.name}`);
    if (actionType !== FacetCutAction.Remove) {
      console.log(`     Address: ${facet.address}`);
      console.log(`     Functions: ${facet.functionSelectors?.length || 0}`);
    }
  });

  console.log("=".repeat(60));

  if (actionType !== FacetCutAction.Remove) {
    console.log("\n📝 Next steps:");
    console.log("1. Update your frontend if any function signatures changed");
    console.log("2. Test all upgraded facet functions thoroughly");
    console.log("3. Update documentation with new facet addresses");
    console.log("4. Monitor the system for any issues");
  }
};

if (require.main === module) {
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}

export { main as upgradeFacetGeneric };
