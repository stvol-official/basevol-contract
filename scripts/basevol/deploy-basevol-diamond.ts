import { ethers, network, run } from "hardhat";
import config from "../../config";

/*
 npx hardhat run --network base_sepolia scripts/basevol/deploy-basevol-diamond.ts
 npx hardhat run --network base scripts/basevol/deploy-basevol-diamond.ts
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

function getSelectors(contractInterface: any, excludeSelectors: string[] = []): string[] {
  const fragments = Object.values(contractInterface.fragments);
  const selectors = fragments
    .filter((fragment: any) => fragment.type === "function")
    .map((fragment: any) => fragment.selector)
    .filter((selector: string) => selector !== undefined)
    .filter((selector: string) => !excludeSelectors.includes(selector));

  if (selectors.length === 0) {
    console.warn(`⚠️ Warning: No selectors found for contract`);
  }

  return selectors;
}

interface DeployedAddresses {
  diamondAddress: string;
  diamondCutFacetAddress: string;
  diamondInitAddress: string;
  facetAddresses: Record<string, string>;
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

export async function deployBaseVolDiamond(
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

  console.log("\n🚀 Deploying BaseVol Diamond with new structure...");
  console.log("Deployer:", deployer.address);

  // 1. Deploy PythLazerLib first (needed for RoundManagementFacet)
  console.log("\n📦 Deploying PythLazerLib...");
  const PythLazerLibFactory = await ethers.getContractFactory("PythLazerLib");
  const pythLazerLib = await PythLazerLibFactory.deploy();
  await pythLazerLib.waitForDeployment();
  const pythLazerLibAddress = await pythLazerLib.getAddress();
  console.log("✅ PythLazerLib deployed to:", pythLazerLibAddress);

  // 2. Deploy DiamondCutFacet (using diamond-common)
  console.log("\n📦 Deploying DiamondCutFacet...");
  const DiamondCutFacet = await ethers.getContractFactory(
    "contracts/diamond-common/facets/DiamondCutFacet.sol:DiamondCutFacet",
  );
  const diamondCutFacet = await DiamondCutFacet.deploy();
  await diamondCutFacet.waitForDeployment();
  const diamondCutFacetAddress = await diamondCutFacet.getAddress();
  console.log("✅ DiamondCutFacet deployed to:", diamondCutFacetAddress);

  // Wait for code to be available
  const hasCode = await waitForContractCode(diamondCutFacetAddress);
  if (!hasCode) {
    throw new Error(`DiamondCutFacet code not available at ${diamondCutFacetAddress}`);
  }

  // 3. Deploy Diamond (using diamond-common)
  console.log("\n💎 Deploying Diamond...");
  const Diamond = await ethers.getContractFactory("contracts/diamond-common/Diamond.sol:Diamond");
  const diamond = await Diamond.deploy(deployer.address, diamondCutFacetAddress);
  await diamond.waitForDeployment();
  const diamondAddress = await diamond.getAddress();
  console.log("✅ Diamond deployed to:", diamondAddress);

  // 4. Deploy DiamondInit (using upgradeInitializers - legacy compatible)
  console.log("\n📦 Deploying DiamondInit...");
  const DiamondInit = await ethers.getContractFactory(
    "contracts/upgradeInitializers/DiamondInit.sol:DiamondInit",
  );
  const diamondInit = await DiamondInit.deploy();
  await diamondInit.waitForDeployment();
  const diamondInitAddress = await diamondInit.getAddress();
  console.log("✅ DiamondInit deployed to:", diamondInitAddress);

  // 5. Deploy all BaseVol facets (from new structure) - Sequential deployment
  console.log("\n📦 Deploying BaseVol Facets (new structure)...");

  const facetAddresses: Record<string, string> = {};

  // DiamondLoupeFacet (using diamond-common)
  console.log("  Deploying DiamondLoupeFacet...");
  const DiamondLoupeFacet = await ethers.getContractFactory(
    "contracts/diamond-common/facets/DiamondLoupeFacet.sol:DiamondLoupeFacet",
  );
  const diamondLoupeFacet = await DiamondLoupeFacet.deploy();
  await diamondLoupeFacet.waitForDeployment();
  const diamondLoupeFacetAddress = await diamondLoupeFacet.getAddress();
  facetAddresses["DiamondLoupeFacet"] = diamondLoupeFacetAddress;
  console.log("  ✅ DiamondLoupeFacet:", diamondLoupeFacetAddress);

  // InitializationFacet (from basevol)
  console.log("  Deploying InitializationFacet...");
  const InitializationFacet = await ethers.getContractFactory(
    "contracts/basevol/facets/InitializationFacet.sol:InitializationFacet",
  );
  const initializationFacet = await InitializationFacet.deploy();
  await initializationFacet.waitForDeployment();
  const initializationFacetAddress = await initializationFacet.getAddress();
  facetAddresses["InitializationFacet"] = initializationFacetAddress;
  console.log("  ✅ InitializationFacet:", initializationFacetAddress);

  // RoundManagementFacet (from basevol, with PythLazerLib)
  console.log("  Deploying RoundManagementFacet...");
  const RoundManagementFacet = await ethers.getContractFactory(
    "contracts/basevol/facets/RoundManagementFacet.sol:RoundManagementFacet",
    {
      libraries: {
        PythLazerLib: pythLazerLibAddress,
      },
    },
  );
  const roundManagementFacet = await RoundManagementFacet.deploy();
  await roundManagementFacet.waitForDeployment();
  const roundManagementFacetAddress = await roundManagementFacet.getAddress();
  facetAddresses["RoundManagementFacet"] = roundManagementFacetAddress;
  console.log("  ✅ RoundManagementFacet:", roundManagementFacetAddress);

  // OrderProcessingFacet (from basevol)
  console.log("  Deploying OrderProcessingFacet...");
  const OrderProcessingFacet = await ethers.getContractFactory(
    "contracts/basevol/facets/OrderProcessingFacet.sol:OrderProcessingFacet",
  );
  const orderProcessingFacet = await OrderProcessingFacet.deploy();
  await orderProcessingFacet.waitForDeployment();
  const orderProcessingFacetAddress = await orderProcessingFacet.getAddress();
  facetAddresses["OrderProcessingFacet"] = orderProcessingFacetAddress;
  console.log("  ✅ OrderProcessingFacet:", orderProcessingFacetAddress);

  // RedemptionFacet (from basevol)
  console.log("  Deploying RedemptionFacet...");
  const RedemptionFacet = await ethers.getContractFactory(
    "contracts/basevol/facets/RedemptionFacet.sol:RedemptionFacet",
  );
  const redemptionFacet = await RedemptionFacet.deploy();
  await redemptionFacet.waitForDeployment();
  const redemptionFacetAddress = await redemptionFacet.getAddress();
  facetAddresses["RedemptionFacet"] = redemptionFacetAddress;
  console.log("  ✅ RedemptionFacet:", redemptionFacetAddress);

  // BaseVolAdminFacet (from basevol)
  console.log("  Deploying BaseVolAdminFacet...");
  const AdminFacet = await ethers.getContractFactory(
    "contracts/basevol/facets/BaseVolAdminFacet.sol:AdminFacet",
  );
  const adminFacet = await AdminFacet.deploy();
  await adminFacet.waitForDeployment();
  const adminFacetAddress = await adminFacet.getAddress();
  facetAddresses["AdminFacet"] = adminFacetAddress;
  console.log("  ✅ AdminFacet:", adminFacetAddress);

  // BaseVolViewFacet (from basevol)
  console.log("  Deploying BaseVolViewFacet...");
  const ViewFacet = await ethers.getContractFactory(
    "contracts/basevol/facets/BaseVolViewFacet.sol:ViewFacet",
  );
  const viewFacet = await ViewFacet.deploy();
  await viewFacet.waitForDeployment();
  const viewFacetAddress = await viewFacet.getAddress();
  facetAddresses["ViewFacet"] = viewFacetAddress;
  console.log("  ✅ ViewFacet:", viewFacetAddress);

  // 6. Verify all facet deployments
  console.log("\n⏳ Verifying contract code availability...");

  const facetsToVerify = [
    { name: "DiamondLoupeFacet", address: diamondLoupeFacetAddress },
    { name: "InitializationFacet", address: initializationFacetAddress },
    { name: "RoundManagementFacet", address: roundManagementFacetAddress },
    { name: "OrderProcessingFacet", address: orderProcessingFacetAddress },
    { name: "RedemptionFacet", address: redemptionFacetAddress },
    { name: "AdminFacet", address: adminFacetAddress },
    { name: "ViewFacet", address: viewFacetAddress },
  ];

  for (const facet of facetsToVerify) {
    const hasCode = await waitForContractCode(facet.address);
    if (!hasCode) {
      throw new Error(`${facet.name} code not available at ${facet.address}`);
    }
    console.log(`  ✅ ${facet.name} verified`);
  }

  // 7. Prepare facet cuts
  console.log("\n🔧 Preparing facet cuts...");
  const FacetCutAction = { Add: 0, Replace: 1, Remove: 2 };
  const cuts: FacetCut[] = [];

  // DiamondLoupeFacet
  const diamondLoupeSelectors = getSelectors(DiamondLoupeFacet.interface);
  console.log(`  DiamondLoupeFacet: ${diamondLoupeSelectors.length} selectors`);
  cuts.push({
    facetAddress: diamondLoupeFacetAddress,
    action: FacetCutAction.Add,
    functionSelectors: diamondLoupeSelectors,
  });

  // InitializationFacet
  const initSelectors = getSelectors(InitializationFacet.interface);
  console.log(`  InitializationFacet: ${initSelectors.length} selectors`);
  if (initSelectors.length > 0) {
    cuts.push({
      facetAddress: initializationFacetAddress,
      action: FacetCutAction.Add,
      functionSelectors: initSelectors,
    });
  }

  // RoundManagementFacet
  const roundMgmtSelectors = getSelectors(RoundManagementFacet.interface);
  console.log(`  RoundManagementFacet: ${roundMgmtSelectors.length} selectors`);
  cuts.push({
    facetAddress: roundManagementFacetAddress,
    action: FacetCutAction.Add,
    functionSelectors: roundMgmtSelectors,
  });

  // OrderProcessingFacet
  const orderProcSelectors = getSelectors(OrderProcessingFacet.interface);
  console.log(`  OrderProcessingFacet: ${orderProcSelectors.length} selectors`);
  cuts.push({
    facetAddress: orderProcessingFacetAddress,
    action: FacetCutAction.Add,
    functionSelectors: orderProcSelectors,
  });

  // RedemptionFacet
  const redemptionSelectors = getSelectors(RedemptionFacet.interface);
  console.log(`  RedemptionFacet: ${redemptionSelectors.length} selectors`);
  cuts.push({
    facetAddress: redemptionFacetAddress,
    action: FacetCutAction.Add,
    functionSelectors: redemptionSelectors,
  });

  // AdminFacet
  const adminSelectors = getSelectors(AdminFacet.interface);
  console.log(`  AdminFacet: ${adminSelectors.length} selectors`);
  cuts.push({
    facetAddress: adminFacetAddress,
    action: FacetCutAction.Add,
    functionSelectors: adminSelectors,
  });

  // ViewFacet
  const viewSelectors = getSelectors(ViewFacet.interface);
  console.log(`  ViewFacet: ${viewSelectors.length} selectors`);
  cuts.push({
    facetAddress: viewFacetAddress,
    action: FacetCutAction.Add,
    functionSelectors: viewSelectors,
  });

  console.log(`\n📊 Total facets to add: ${cuts.length}`);

  // 8. Execute diamond cut with initialization
  console.log("\n🔪 Executing diamondCut with initialization...");
  const diamondCut = await ethers.getContractAt(
    "contracts/diamond-common/interfaces/IDiamondCut.sol:IDiamondCut",
    diamondAddress,
  );

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

  try {
    const tx = await diamondCut.diamondCut(cuts, diamondInitAddress, functionCall);
    console.log(`  📝 Transaction hash: ${tx.hash}`);
    console.log("  ⏳ Waiting for confirmation...");

    const receipt = await tx.wait();
    if (!receipt || receipt.status !== 1) {
      throw Error(`Diamond cut failed: ${tx.hash}`);
    }

    console.log(`  ✅ Diamond cut completed in block ${receipt.blockNumber}`);
  } catch (error: any) {
    console.error("\n❌ Diamond cut failed!");
    console.error("Error:", error.message);

    // Try to decode the error
    if (error.data) {
      try {
        const iface = new ethers.Interface([
          "error LibDiamond__NoSelectorsProvidedForFacetForCut(address facet)",
          "error LibDiamond__CannotAddSelectorsToZeroAddress(bytes4[] selectors)",
          "error LibDiamond__NoBytecodeAtAddress(address contractAddress, string message)",
        ]);
        const decodedError = iface.parseError(error.data);
        console.error("Decoded error:", decodedError);
      } catch (decodeError) {
        console.error("Could not decode error data");
      }
    }
    throw error;
  }

  // Wait for network propagation
  console.log("\n⏳ Waiting for network state to propagate (3 seconds)...");
  await sleep(3000);

  // 7. Verify the diamond is working
  console.log("\n🔍 Verifying Diamond setup...");
  try {
    const viewFacetContract = await ethers.getContractAt(
      "contracts/basevol/facets/BaseVolViewFacet.sol:ViewFacet",
      diamondAddress,
    );
    const commissionFeeFromContract = await viewFacetContract.commissionfee();
    console.log("  ✅ Commission fee:", commissionFeeFromContract.toString());

    const roundManagementFacetContract = await ethers.getContractAt(
      "contracts/basevol/facets/RoundManagementFacet.sol:RoundManagementFacet",
      diamondAddress,
    );
    const currentEpoch = await roundManagementFacetContract.currentEpoch();
    console.log("  ✅ Current epoch:", currentEpoch.toString());

    console.log("✅ Diamond verification successful!");
  } catch (error) {
    console.error("❌ Diamond verification failed:", error);
    throw error;
  }

  return {
    diamondAddress,
    diamondCutFacetAddress,
    diamondInitAddress,
    facetAddresses,
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

  const contractName = "BaseVol Diamond (New Structure)";
  console.log(`\n🌐 Deploying ${contractName} to ${networkName} network...`);

  // Check if the addresses in the config are set
  if (
    config.Address.Usdc[networkName] === ethers.ZeroAddress ||
    config.Address.Oracle[networkName] === ethers.ZeroAddress ||
    config.Address.Admin[networkName] === ethers.ZeroAddress ||
    config.Address.Operator[networkName] === ethers.ZeroAddress ||
    config.Address.ClearingHouse[networkName] === ethers.ZeroAddress
  ) {
    throw new Error("Missing addresses (Pyth Oracle and/or Admin/Operator/ClearingHouse)");
  }

  // Compile contracts
  await run("compile");
  console.log("✅ Compiled contracts...");

  const [deployer] = await ethers.getSigners();
  console.log("===========================================");
  console.log("Owner: %s", deployer.address);
  console.log("Usdc: %s", config.Address.Usdc[networkName]);
  console.log("Oracle: %s", config.Address.Oracle[networkName]);
  console.log("Admin: %s", config.Address.Admin[networkName]);
  console.log("Operator: %s", config.Address.Operator[networkName]);
  console.log("CommissionFee: %s", config.CommissionFee[networkName]);
  console.log("ClearingHouse: %s", config.Address.ClearingHouse[networkName]);
  console.log("===========================================");

  // Default parameters for OneDay
  const startTimestamp = 1751356800; // 2025-07-01 08:00:00
  const intervalSeconds = 86400; // 1 day

  console.log("StartTimestamp: %s", startTimestamp);
  console.log("IntervalSeconds: %s", intervalSeconds);

  // Deploy diamond contracts
  const { diamondAddress, diamondCutFacetAddress, diamondInitAddress, facetAddresses } =
    await deployBaseVolDiamond(
      config.Address.Usdc[networkName],
      config.Address.Oracle[networkName],
      config.Address.Admin[networkName],
      config.Address.Operator[networkName],
      config.CommissionFee[networkName],
      config.Address.ClearingHouse[networkName],
      startTimestamp,
      intervalSeconds,
    );

  // Print summary
  console.log("\n\n🎉 BaseVol Diamond Deployment Summary");
  console.log("===========================================");
  console.log("Diamond Address:", diamondAddress);
  console.log("Network:", networkName);
  console.log("Owner:", deployer.address);
  console.log("===========================================");
  console.log("\n📋 Core Contracts:");
  console.log("- DiamondCutFacet:", diamondCutFacetAddress);
  console.log("- DiamondInit:", diamondInitAddress);
  console.log("\n📋 Facets (New Structure - contracts/basevol/facets):");
  console.log("- DiamondLoupeFacet:", facetAddresses["DiamondLoupeFacet"]);
  console.log("- InitializationFacet:", facetAddresses["InitializationFacet"]);
  console.log("- RoundManagementFacet:", facetAddresses["RoundManagementFacet"]);
  console.log("- OrderProcessingFacet:", facetAddresses["OrderProcessingFacet"]);
  console.log("- RedemptionFacet:", facetAddresses["RedemptionFacet"]);
  console.log("- AdminFacet:", facetAddresses["AdminFacet"]);
  console.log("- ViewFacet:", facetAddresses["ViewFacet"]);
  console.log("===========================================");

  console.log("\n📝 Next steps:");
  console.log("1. Verify contracts on block explorer");
  console.log("2. Test all facet functions");
  console.log("3. Update frontend with new Diamond address");
  console.log("4. Use upgrade-basevol-facet.ts for mainnet facet upgrades");
};

if (require.main === module) {
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}

export { main as deployBaseVolDiamondScript };
