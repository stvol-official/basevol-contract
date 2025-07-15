import { ethers, network, run } from "hardhat";
import config from "../config";

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
  const signatures = Object.keys(contract.interface.fragments);
  return signatures.reduce((acc: string[], val: string) => {
    if (val !== "init(bytes)") {
      acc.push(contract.interface.getFunction(val).selector);
    }
    return acc;
  }, []);
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
): Promise<{ diamondAddress: string; diamondCutFacetAddress: string }> {
  const [deployer] = await ethers.getSigners();

  console.log("Deploying Diamond with account:", deployer.address);

  // 1. Deploy DiamondCutFacet
  const DiamondCutFacet = await ethers.getContractFactory("DiamondCutFacet");
  const diamondCutFacet = await DiamondCutFacet.deploy();
  await diamondCutFacet.waitForDeployment();
  const diamondCutFacetAddress = await diamondCutFacet.getAddress();
  console.log("DiamondCutFacet deployed to:", diamondCutFacetAddress);

  // 2. Deploy Diamond
  const Diamond = await ethers.getContractFactory("Diamond");
  const diamond = await Diamond.deploy(deployer.address, diamondCutFacetAddress);
  await diamond.waitForDeployment();
  const diamondAddress = await diamond.getAddress();
  console.log("Diamond deployed to:", diamondAddress);

  // 3. Deploy DiamondInit
  const DiamondInit = await ethers.getContractFactory("DiamondInit");
  const diamondInit = await DiamondInit.deploy();
  await diamondInit.waitForDeployment();
  console.log("DiamondInit deployed to:", await diamondInit.getAddress());

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

  for (const FacetName of facetNames) {
    const Facet = await ethers.getContractFactory(FacetName);
    const facet = await Facet.deploy();
    await facet.waitForDeployment();

    console.log(`${FacetName} deployed to:`, await facet.getAddress());

    cut.push({
      facetAddress: await facet.getAddress(),
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

  const tx = await diamondCut.diamondCut(cut, await diamondInit.getAddress(), functionCall);
  console.log("Diamond cut tx:", tx.hash);

  const receipt = await tx.wait();
  if (!receipt || receipt.status !== 1) {
    throw Error(`Diamond upgrade failed: ${tx.hash}`);
  }

  console.log("Diamond cut completed");

  // 6. Initialize the diamond using InitializationFacet
  const initializationFacet = await ethers.getContractAt(
    "InitializationFacet",
    await diamond.getAddress(),
  );

  const initTx = await initializationFacet.initialize(
    usdcAddress,
    oracleAddress,
    adminAddress,
    operatorAddress,
    commissionFee,
    clearingHouseAddress,
    startTimestamp,
    intervalSeconds,
  );

  console.log("Diamond initialization tx:", initTx.hash);

  const initReceipt = await initTx.wait();
  if (!initReceipt || initReceipt.status !== 1) {
    throw Error(`Diamond initialization failed: ${initTx.hash}`);
  }

  console.log("Diamond initialization completed");

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

  return { diamondAddress, diamondCutFacetAddress };
}
