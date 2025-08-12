import { ethers } from "hardhat";

/*
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

  // 1. Deploy DiamondCutFacet
  const DiamondCutFacet = await ethers.getContractFactory("DiamondCutFacet");
  const diamondCutFacet = await deployWithRetry(DiamondCutFacet);
  const diamondCutFacetAddress = await diamondCutFacet.getAddress();
  console.log("DiamondCutFacet deployed to:", diamondCutFacetAddress);

  // 2. Deploy Diamond
  const Diamond = await ethers.getContractFactory("Diamond");
  const diamond = await deployWithRetry(Diamond, [deployer.address, diamondCutFacetAddress]);
  const diamondAddress = await diamond.getAddress();
  console.log("Diamond deployed to:", diamondAddress);

  // 3. Deploy DiamondInit
  const DiamondInit = await ethers.getContractFactory("DiamondInit");
  const diamondInit = await deployWithRetry(DiamondInit);
  const diamondInitAddress = await diamondInit.getAddress();
  console.log("DiamondInit deployed to:", diamondInitAddress);

  // 4. Deploy all facets
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

  for (const FacetName of facetNames) {
    const Facet = await ethers.getContractFactory(FacetName);
    const facet = await deployWithRetry(Facet);

    const facetAddress = await facet.getAddress();
    facetAddresses[FacetName] = facetAddress;
    console.log(`${FacetName} deployed to:`, facetAddress);

    cut.push({
      facetAddress: facetAddress,
      action: FacetCutAction.Add,
      functionSelectors: getSelectors(facet),
    });
  }

  // 5. Execute diamond cut
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
  const viewFacet = await ethers.getContractAt("ViewFacet", await diamond.getAddress());
  const roundManagementFacet = await ethers.getContractAt(
    "RoundManagementFacet",
    await diamond.getAddress(),
  );

  const commissionFeeFromContract = await viewFacet.commissionfee();
  const currentEpoch = await roundManagementFacet.currentEpoch();

  console.log("Commission fee:", commissionFeeFromContract.toString());
  console.log("Current epoch:", currentEpoch.toString());

  return {
    diamondAddress,
    diamondCutFacetAddress,
    diamondInitAddress,
    facetAddresses,
  };
}
