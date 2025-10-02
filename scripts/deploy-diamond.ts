import { ethers } from "hardhat";
import input from "@inquirer/input";

/*
 ⚠️  LEGACY SCRIPT - FOR BACKUP PURPOSES ONLY ⚠️
 
 This script uses the OLD Diamond structure (contracts/Diamond.sol, contracts/facets/*).
 The project has been migrated to a NEW Diamond structure.
 
 For NEW deployments, use:
   npx hardhat run --network base_sepolia scripts/basevol/deploy-basevol-diamond.ts
   npx hardhat run --network base scripts/basevol/deploy-basevol-diamond.ts
 
 Only use this script if you specifically need to deploy using the legacy structure.
 
 Original commands (LEGACY):
   npx hardhat run --network base_sepolia scripts/deploy-diamond.ts
   npx hardhat run --network base scripts/deploy-diamond.ts
*/
const NETWORK = ["base_sepolia", "base"] as const;
type SupportedNetwork = (typeof NETWORK)[number];

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

interface DeployedAddresses {
  diamondAddress: string;
  diamondCutFacetAddress: string;
  diamondInitAddress: string;
  facetAddresses: Record<string, string>;
}

export async function deployDiamond(
  usdcAddress: string,
  oracleAddress: string,
  adminAddress: string,
  operatorAddress: string,
  commissionFee: number,
  clearingHouseAddress: string,
  startTimestamp: number,
  intervalSeconds: number,
): Promise<DeployedAddresses> {
  // Show legacy warning
  console.log("\n" + "=".repeat(80));
  console.log("⚠️  LEGACY DEPLOYMENT WARNING ⚠️");
  console.log("=".repeat(80));
  console.log("This script deploys using the LEGACY Diamond structure:");
  console.log("  - contracts/Diamond.sol");
  console.log("  - contracts/facets/*");
  console.log("");
  console.log("The project has been migrated to a NEW structure:");
  console.log("  - contracts/diamond-common/");
  console.log("  - contracts/basevol/");
  console.log("");
  console.log("For NEW deployments, please use:");
  console.log("  npx hardhat run --network <network> scripts/basevol/deploy-basevol-diamond.ts");
  console.log("=".repeat(80) + "\n");

  const shouldContinue = await input({
    message: "Are you sure you want to deploy using the LEGACY structure? (yes/no)",
    default: "no",
    validate: (val) => {
      return ["yes", "no", "y", "n"].includes(val.toLowerCase()) || "Please enter yes or no";
    },
  });

  if (!["yes", "y"].includes(shouldContinue.toLowerCase())) {
    console.log("❌ Deployment cancelled by user");
    process.exit(0);
  }

  const [deployer] = await ethers.getSigners();

  console.log("Deploying Diamond with account:", deployer.address);

  // Get initial nonce and track it manually
  let nonce = await deployer.getNonce();
  console.log("Starting nonce:", nonce);

  // Helper function to wait for transaction and increment nonce
  const waitAndIncrementNonce = async (tx: any) => {
    const receipt = await tx.wait();
    nonce++;
    console.log(`Transaction confirmed. New nonce: ${nonce}`);
    return receipt;
  };

  // Helper function to deploy contract with retry mechanism
  const deployWithRetry = async (
    contractFactory: any,
    args: any[] = [],
    maxRetries = 3,
  ): Promise<any> => {
    for (let attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        console.log(`Deployment attempt ${attempt}/${maxRetries} with nonce ${nonce}`);
        const contract =
          args.length > 0
            ? await contractFactory.deploy(...args, { nonce })
            : await contractFactory.deploy({ nonce });

        await waitAndIncrementNonce(contract.deploymentTransaction());
        return contract;
      } catch (error: any) {
        console.log(`Deployment attempt ${attempt} failed:`, error.message);

        if (attempt === maxRetries) {
          throw error;
        }

        // Update nonce from network in case of nonce mismatch
        nonce = await deployer.getNonce();
        console.log(`Updated nonce to: ${nonce}`);

        // Wait before retry
        await new Promise((resolve) => setTimeout(resolve, 2000));
      }
    }
  };

  // 1. Deploy PythLazerLib first
  const PythLazerLibFactory = await ethers.getContractFactory("PythLazerLib");
  const pythLazerLib = await PythLazerLibFactory.deploy();
  await pythLazerLib.waitForDeployment();
  const pythLazerLibAddress = await pythLazerLib.getAddress();
  console.log("PythLazerLib deployed to:", pythLazerLibAddress);

  // 2. Deploy DiamondCutFacet
  const DiamondCutFacet = await ethers.getContractFactory("DiamondCutFacet");
  const diamondCutFacet = await deployWithRetry(DiamondCutFacet);
  const diamondCutFacetAddress = await diamondCutFacet.getAddress();
  console.log("DiamondCutFacet deployed to:", diamondCutFacetAddress);

  // 3. Deploy Diamond
  const Diamond = await ethers.getContractFactory("Diamond");
  const diamond = await deployWithRetry(Diamond, [deployer.address, diamondCutFacetAddress]);
  const diamondAddress = await diamond.getAddress();
  console.log("Diamond deployed to:", diamondAddress);

  // 4. Deploy DiamondInit
  const DiamondInit = await ethers.getContractFactory("DiamondInit");
  const diamondInit = await deployWithRetry(DiamondInit);
  const diamondInitAddress = await diamondInit.getAddress();
  console.log("DiamondInit deployed to:", diamondInitAddress);

  // 5. Deploy all facets with PythLazerLib library
  const facetNames = [
    "DiamondLoupeFacet",
    "InitializationFacet",
    "RoundManagementFacet",
    "OrderProcessingFacet",
    "RedemptionFacet",
    "AdminFacet",
    "ViewFacet",
  ];

  const cut: FacetCut[] = [];
  const facetAddresses: Record<string, string> = {};

  const facetsWithPythLazerLib = ["RoundManagementFacet"];

  for (const FacetName of facetNames) {
    let Facet;
    if (facetsWithPythLazerLib.includes(FacetName)) {
      Facet = await ethers.getContractFactory(FacetName, {
        libraries: {
          PythLazerLib: pythLazerLibAddress,
        },
      });
    } else {
      Facet = await ethers.getContractFactory(FacetName);
    }
    const facet = await Facet.deploy();
    await facet.waitForDeployment();

    const facetAddress = await facet.getAddress();
    facetAddresses[FacetName] = facetAddress;
    console.log(`${FacetName} deployed to:`, facetAddress);

    cut.push({
      facetAddress: facetAddress,
      action: FacetCutAction.Add,
      functionSelectors: getSelectors(facet),
    });
  }

  // 6. Execute diamond cut
  const diamondCut = await ethers.getContractAt("IDiamondCut", await diamond.getAddress());

  const functionCall = diamondInit.interface.encodeFunctionData("init", [
    usdcAddress,
    oracleAddress,
    adminAddress,
    operatorAddress,
    commissionFee,
    clearingHouseAddress,
    startTimestamp,
    intervalSeconds,
  ]);

  console.log("Cut:", cut);

  // Execute diamond cut with retry mechanism
  let receipt;
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      console.log(`Diamond cut attempt ${attempt}/3 with nonce ${nonce}`);
      const tx = await diamondCut.diamondCut(cut, await diamondInit.getAddress(), functionCall, {
        nonce,
      });
      console.log("Diamond cut tx:", tx.hash);

      receipt = await waitAndIncrementNonce(tx);
      if (receipt && receipt.status === 1) {
        break;
      } else {
        throw new Error(`Diamond cut failed with status: ${receipt?.status}`);
      }
    } catch (error: any) {
      console.log(`Diamond cut attempt ${attempt} failed:`, error.message);

      if (attempt === 3) {
        throw error;
      }

      // Update nonce from network in case of nonce mismatch
      nonce = await deployer.getNonce();
      console.log(`Updated nonce to: ${nonce}`);

      // Wait before retry
      await new Promise((resolve) => setTimeout(resolve, 3000));
    }
  }

  if (!receipt || receipt.status !== 1) {
    throw Error(`Diamond upgrade failed after all retries`);
  }

  console.log("Diamond cut completed");

  // Diamond is already initialized by DiamondInit during the cut process
  console.log("Diamond initialization completed via DiamondInit");

  // 7. Verify the diamond is working
  console.log("Waiting for diamond cut to be fully processed...");
  await new Promise((resolve) => setTimeout(resolve, 5000)); // 5초 대기

  try {
    const viewFacet = await ethers.getContractAt("ViewFacet", await diamond.getAddress());
    const roundManagementFacet = await ethers.getContractAt(
      "RoundManagementFacet",
      await diamond.getAddress(),
    );

    // 각 facet의 함수들이 제대로 등록되었는지 확인
    console.log("Verifying ViewFacet functions...");
    const commissionFeeFromContract = await viewFacet.commissionfee();
    console.log("Commission fee:", commissionFeeFromContract.toString());

    console.log("Verifying RoundManagementFacet functions...");
    const currentEpoch = await roundManagementFacet.currentEpoch();
    console.log("Current epoch:", currentEpoch.toString());

    console.log("✅ Diamond verification successful!");
  } catch (error) {
    console.error("❌ Diamond verification failed:", error);

    // Diamond cut 상태 확인
    const diamondLoupe = await ethers.getContractAt("IDiamondLoupe", await diamond.getAddress());
    const facets = await diamondLoupe.facets();
    console.log("Registered facets:", facets);

    // ViewFacet과 RoundManagementFacet의 주소 확인
    console.log("Expected ViewFacet address:", facetAddresses["ViewFacet"]);
    console.log("Expected RoundManagementFacet address:", facetAddresses["RoundManagementFacet"]);

    throw error;
  }

  return {
    diamondAddress,
    diamondCutFacetAddress,
    diamondInitAddress,
    facetAddresses,
  };
}
