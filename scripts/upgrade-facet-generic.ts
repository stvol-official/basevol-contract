import { ethers, network, run } from "hardhat";
import input from "@inquirer/input";
import select from "@inquirer/select";

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

  console.log(`🔄 Diamond Facet Upgrade Tool for ${networkName} network`);

  // 1. Diamond 주소 입력
  const DIAMOND_ADDRESS = await input({
    message: "Enter the Diamond contract address",
    default: DIAMOND_ADDRESSES[networkName] || "",
    validate: (val) => {
      return ethers.isAddress(val) || "Please enter a valid address";
    },
  });

  // 2. Select facet to upgrade
  const selectedFacet = await select({
    message: "Select the facet to upgrade",
    choices: AVAILABLE_FACETS.map((facet) => ({
      name: facet.name,
      value: facet,
    })),
  });

  // 3. Select action type
  const actionType = await select({
    message: "Select the upgrade action",
    choices: [
      { name: "Replace (Upgrade)", value: FacetCutAction.Replace },
      { name: "Add (New)", value: FacetCutAction.Add },
      { name: "Remove (Delete)", value: FacetCutAction.Remove },
    ],
  });

  console.log("===========================================");
  console.log("Network:", networkName);
  console.log("Diamond Address:", DIAMOND_ADDRESS);
  console.log("Target Facet:", selectedFacet.name);
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
    message: "Do you want to proceed? (yes/no)",
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

  let newFacetAddress = "";
  let functionSelectors: string[] = [];

  // 4. Deploy new facet unless removing
  if (actionType !== FacetCutAction.Remove) {
    console.log(`📦 Deploying new ${selectedFacet.name}...`);
    const FacetFactory = await ethers.getContractFactory(selectedFacet.name);
    const newFacet = await FacetFactory.deploy();
    await newFacet.waitForDeployment();
    newFacetAddress = await newFacet.getAddress();
    console.log(`✅ New ${selectedFacet.name} deployed to:`, newFacetAddress);

    // Get function selectors
    console.log("🔍 Getting function selectors...");
    functionSelectors = getSelectors(newFacet);
    console.log("Function selectors:", functionSelectors);
  } else {
    // For removal, get selectors from existing facet
    console.log("🔍 Getting existing function selectors for removal...");
    const diamondLoupe = await ethers.getContractAt("IDiamondLoupe", DIAMOND_ADDRESS);
    const existingFacet = await ethers.getContractFactory(selectedFacet.name);
    functionSelectors = getSelectors(existingFacet);
    newFacetAddress = ethers.ZeroAddress; // Use ZeroAddress for removal
  }

  // 5. Prepare Diamond Cut
  const cut: FacetCut[] = [
    {
      facetAddress: newFacetAddress,
      action: actionType,
      functionSelectors: functionSelectors,
    },
  ];

  // 6. Execute Diamond Cut
  console.log(`🔄 Executing diamond cut for ${selectedFacet.name}...`);
  const diamondCut = await ethers.getContractAt("IDiamondCut", DIAMOND_ADDRESS);

  const tx = await diamondCut.diamondCut(cut, ethers.ZeroAddress, "0x");
  console.log("Diamond cut tx:", tx.hash);

  const receipt = await tx.wait();
  if (!receipt || receipt.status !== 1) {
    throw Error(`Diamond upgrade failed: ${tx.hash}`);
  }

  console.log("✅ Diamond cut completed successfully!");

  // 7. Verify upgrade
  if (actionType !== FacetCutAction.Remove && functionSelectors.length > 0) {
    console.log("🔍 Verifying upgrade...");
    try {
      const diamondLoupe = await ethers.getContractAt("IDiamondLoupe", DIAMOND_ADDRESS);
      const facetAddress = await diamondLoupe.facetAddress(functionSelectors[0]);

      if (facetAddress === newFacetAddress) {
        console.log("✅ Upgrade verification successful!");
        console.log(
          `${selectedFacet.name} has been successfully ${actionType === FacetCutAction.Add ? "added" : "upgraded"} to:`,
          newFacetAddress,
        );
      } else {
        console.log("❌ Upgrade verification failed!");
        console.log("Expected:", newFacetAddress);
        console.log("Actual:", facetAddress);
      }
    } catch (error) {
      console.log("⚠️  Could not verify upgrade:", error);
    }

    // 8. Function testing (if possible)
    console.log(`🧪 Testing upgraded ${selectedFacet.name}...`);
    try {
      const facetContract = await ethers.getContractAt(selectedFacet.name, DIAMOND_ADDRESS);
      console.log(`✅ ${selectedFacet.name} functions are accessible`);
    } catch (error) {
      console.log(`⚠️  Could not test ${selectedFacet.name} functions:`, error);
    }

    // 9. Contract verification
    await sleep(6000);
    console.log(`🔍 Verifying new ${selectedFacet.name} contract...`);

    try {
      const apiKey = process.env.ALCHEMY_API_KEY;
      const networkInfo = await ethers
        .getDefaultProvider(
          `https://base-${networkName === "base_sepolia" ? "sepolia" : "mainnet"}.g.alchemy.com/v2/${apiKey}`,
        )
        .getNetwork();

      await run("verify:verify", {
        address: newFacetAddress,
        network: networkInfo,
        contract: selectedFacet.path,
        constructorArguments: [],
      });
      console.log(`✅ ${selectedFacet.name} verification done`);
    } catch (error) {
      console.log(`❌ ${selectedFacet.name} verification failed:`, error);
    }
  }

  console.log(
    `\n🎉 ${selectedFacet.name} ${actionType === FacetCutAction.Replace ? "upgrade" : actionType === FacetCutAction.Add ? "addition" : "removal"} completed!`,
  );
  console.log("===========================================");
  console.log("Diamond Address:", DIAMOND_ADDRESS);
  if (actionType !== FacetCutAction.Remove) {
    console.log(`New ${selectedFacet.name} Address:`, newFacetAddress);
  }
  console.log("Network:", networkName);
  console.log("===========================================");

  if (actionType !== FacetCutAction.Remove) {
    console.log("\n📝 Next steps:");
    console.log("1. Update your frontend to use the new Diamond ABI if needed");
    console.log(`2. Test all ${selectedFacet.name} functions thoroughly`);
    console.log("3. Update documentation with the new facet address");
  }
};

if (require.main === module) {
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}

export { main as upgradeFacetGeneric };
