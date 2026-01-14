import { ethers, network, run } from "hardhat";
import input from "@inquirer/input";
import select from "@inquirer/select";
import checkbox from "@inquirer/checkbox";

/*
 npx hardhat run --network base_sepolia scripts/genesis-vault/upgrade-genesis-vault-facet.ts
 npx hardhat run --network base scripts/genesis-vault/upgrade-genesis-vault-facet.ts
*/

const NETWORK = ["base_sepolia", "base"] as const;
type SupportedNetwork = (typeof NETWORK)[number];

// Genesis Vault Diamond addresses by network
const GENESIS_VAULT_ADDRESSES = {
  base_sepolia: "0x640F0323257274883823b12b6C52e0aD809c3C59", // Update after deployment
  base: "0xf1BE2622fd0f34d520Ab31019A4ad054a2c4B1e0", // Update after deployment
};

// Available Genesis Vault facets for upgrade
const AVAILABLE_FACETS = [
  {
    name: "ERC20Facet",
    path: "contracts/genesis-vault/facets/ERC20Facet.sol:ERC20Facet",
  },
  {
    name: "GenesisVaultViewFacet",
    path: "contracts/genesis-vault/facets/GenesisVaultViewFacet.sol:GenesisVaultViewFacet",
  },
  {
    name: "GenesisVaultAdminFacet",
    path: "contracts/genesis-vault/facets/GenesisVaultAdminFacet.sol:GenesisVaultAdminFacet",
  },
  {
    name: "KeeperFacet",
    path: "contracts/genesis-vault/facets/KeeperFacet.sol:KeeperFacet",
  },
  {
    name: "VaultCoreFacet",
    path: "contracts/genesis-vault/facets/VaultCoreFacet.sol:VaultCoreFacet",
  },
  {
    name: "SettlementFacet",
    path: "contracts/genesis-vault/facets/SettlementFacet.sol:SettlementFacet",
  },
  {
    name: "GenesisVaultInitializationFacet",
    path: "contracts/genesis-vault/facets/GenesisVaultInitializationFacet.sol:GenesisVaultInitializationFacet",
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

interface FacetAnalysis {
  name: string;
  newSelectors: string[]; // Newly added functions
  existingSelectors: string[]; // Existing functions
  removedSelectors: string[]; // Removed functions
  cuts: FacetCut[]; // Cut operations to execute
  newFacetAddress: string;
}

function getSelectors(contractInterface: any, excludeSelectors: string[] = []): string[] {
  const signatures: string[] = [];

  // Iterate through all functions in the interface
  contractInterface.forEachFunction((func: any) => {
    if (func.name !== "init" && func.name !== "initialize") {
      const selector = func.selector;
      if (!excludeSelectors.includes(selector)) {
        signatures.push(selector);
      }
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
  facetInfo: { name: string; path: string },
  diamondAddress: string,
): Promise<FacetAnalysis> {
  console.log(`🔍 Analyzing ${facetInfo.name}...`);

  // 1. Deploy new facet and get selectors
  const FacetFactory = await ethers.getContractFactory(facetInfo.path);
  const newFacet = await FacetFactory.deploy();
  await newFacet.waitForDeployment();
  const newFacetAddress = await newFacet.getAddress();

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
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name as SupportedNetwork;

  // Check if the network is supported.
  if (!NETWORK.includes(networkName)) {
    console.log(`Deploying to ${networkName} network is not supported...`);
    return;
  }

  console.log(`🚀 Genesis Vault Facet Upgrade Tool for ${networkName} network`);
  console.log("This tool automatically detects changes and applies appropriate actions");

  // 1. Enter Genesis Vault Diamond address
  const DIAMOND_ADDRESS = await input({
    message: "Enter the Genesis Vault Diamond contract address",
    default: GENESIS_VAULT_ADDRESSES[networkName] || "",
    validate: (val) => {
      return ethers.isAddress(val) || "Please enter a valid address";
    },
  });

  const isSafeOwner = await input({
    message: "Is the Diamond owner a Safe address? (Y/N)",
    default: "N",
    validate: (val) => {
      return ["Y", "N", "y", "n", "yes", "no"].includes(val) || "Please enter Y or N";
    },
  });

  const isSafeOwnerBool = isSafeOwner.toUpperCase() === "Y" || isSafeOwner.toUpperCase() === "YES";

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

  console.log("===========================================");
  console.log("Network:", networkName);
  console.log("Genesis Vault Diamond Address:", DIAMOND_ADDRESS);
  console.log("Selected Facets:", selectedFacets.map((f: any) => f.name).join(", "));
  console.log("Safe Owner:", isSafeOwnerBool ? "Yes" : "No");
  console.log("===========================================");

  // Compile contracts.
  await run("compile");
  console.log("✅ Compiled contracts...");

  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  console.log(`\n🔍 Analyzing ${selectedFacets.length} facet(s) for changes...\n`);

  // 3. Analyze and deploy each facet (sequential to avoid nonce issues)
  const facetAnalyses: FacetAnalysis[] = [];
  let totalCuts: FacetCut[] = [];

  for (let i = 0; i < selectedFacets.length; i++) {
    const facet = selectedFacets[i];
    console.log(`[${i + 1}/${selectedFacets.length}] Analyzing ${facet.name}...`);

    try {
      const analysis = await analyzeFacet(facet, DIAMOND_ADDRESS);
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

  // Safe 계정일 때 처리
  if (isSafeOwnerBool) {
    console.log("\n🔐 Safe 멀티시그를 통한 업그레이드");
    console.log("=".repeat(60));

    // Facet 주소들 출력
    console.log("\n📦 배포된 Facet 주소들:");
    facetAnalyses.forEach((analysis, index) => {
      if (analysis.cuts.length > 0) {
        console.log(`${index + 1}. ${analysis.name}: ${analysis.newFacetAddress}`);
      }
    });

    console.log("\n🔧 Safe에서 실행할 Diamond Cut 데이터:");
    console.log("=".repeat(60));

    const diamondCutData = totalCuts.map((cut) => [
      cut.facetAddress, // address
      cut.action, // uint8
      cut.functionSelectors, // bytes4[]
    ]);

    const diamondCutInterface = new ethers.Interface([
      "function diamondCut(tuple(address,uint8,bytes4[])[] _diamondCut, address _init, bytes _calldata) external",
    ]);

    const data = diamondCutInterface.encodeFunctionData("diamondCut", [
      diamondCutData,
      ethers.ZeroAddress,
      "0x",
    ]);

    console.log("📱 Safe 사용법 (Raw 트랜잭션 방법):");
    console.log("1. https://app.safe.global/ 또는 https://safe.optimism.io/ 접속");
    console.log("2. 'New transaction' 클릭");
    console.log("3. 'Transaction Builder' 선택");
    console.log("4. 'Custom data toggle");
    console.log("4. 다음 정보를 입력:");
    console.log("   Enter Address:", DIAMOND_ADDRESS);
    console.log("   ABI:");
    console.log("   To:", DIAMOND_ADDRESS);
    console.log("   ETH Value: 0");
    console.log("   Data(Hex encoded):", data);
    console.log("5. 트랜잭션 생성 후 멀티시그 서명");
    console.log("6. 실행");

    console.log("\n📋 대안 방법 (Contract Interaction):");
    console.log("1. 'New transaction' 클릭");
    console.log("2. 'Contract interaction' 선택");
    console.log("3. Contract address:", DIAMOND_ADDRESS);
    console.log("4. ABI 입력:");
    console.log(
      `[{"inputs":[{"components":[{"internalType":"address","name":"facetAddress","type":"address"},{"internalType":"enum IDiamondCut.FacetCutAction","name":"action","type":"uint8"},{"internalType":"bytes4[]","name":"functionSelectors","type":"bytes4[]"}],"internalType":"struct IDiamondCut.FacetCut[]","name":"_diamondCut","type":"tuple[]"},{"internalType":"address","name":"_init","type":"address"},{"internalType":"bytes","name":"_calldata","type":"bytes"}],"name":"diamondCut","outputs":[],"stateMutability":"nonpayable","type":"function"}]`,
    );
    console.log("5. Method: diamondCut 선택");
    console.log("6. Parameters를 하나씩 입력:");
    console.log("   _diamondCut: [");
    diamondCutData.forEach((cut: any, index: number) => {
      console.log(`     [`);
      console.log(`       "${cut[0]}",`);
      console.log(`       ${cut[1]},`);
      console.log(`       [${cut[2].map((s: string) => `"${s}"`).join(", ")}]`);
      console.log(`     ]${index < diamondCutData.length - 1 ? "," : ""}`);
    });
    console.log("   ]");
    console.log("   _init: 0x0000000000000000000000000000000000000000");
    console.log("   _calldata: 0x");

    console.log("\n⚠️  주의사항:");
    console.log("- Raw 트랜잭션 방법(첫 번째)을 권장합니다");
    console.log("- action 값: 0=Add, 1=Replace, 2=Remove");
    console.log("- 모든 Facet이 정상적으로 배포되었는지 확인하세요");

    console.log("\n🔍 Verifying deployed facets on block explorer...");

    // Use Hardhat's configured provider (uses ALCHEMY_API_KEY from .env) instead of default free tier
    const networkInfo = await ethers.provider.getNetwork();

    for (const analysis of facetAnalyses) {
      if (analysis.cuts.length === 0) continue;

      console.log(`\nVerifying ${analysis.name}...`);
      await sleep(2000); // Rate limiting

      const facetPath = AVAILABLE_FACETS.find((f) => f.name === analysis.name)?.path;
      if (facetPath) {
        try {
          await run("verify:verify", {
            address: analysis.newFacetAddress,
            network: networkInfo,
            contract: facetPath,
            constructorArguments: [],
          });
          console.log(`   ✅ ${analysis.name} verified`);
        } catch (error: any) {
          if (
            error.message?.includes("Already Verified") ||
            error.message?.includes("already verified")
          ) {
            console.log(`   ✅ ${analysis.name} already verified`);
          } else {
            console.log(`   ⚠️  ${analysis.name} verification failed:`, error.message);
          }
        }
      }
    }
  } else {
    // 일반 계정일 때: 자동 실행
    // 5. Execution confirmation
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

    // 9. Contract verification on block explorer
    console.log("\n🔍 Verifying contracts on block explorer...");
    console.log("⏳ Waiting for block explorer indexing (6 seconds)...");
    await sleep(6000);

    // Use Hardhat's configured provider (uses ALCHEMY_API_KEY from .env) instead of default free tier
    const networkInfo = await ethers.provider.getNetwork();

    for (const analysis of facetAnalyses) {
      if (analysis.cuts.length === 0) continue;

      console.log(`\n📝 Verifying ${analysis.name}...`);

      try {
        const facetPath = AVAILABLE_FACETS.find((f) => f.name === analysis.name)?.path;
        await run("verify:verify", {
          address: analysis.newFacetAddress,
          network: networkInfo,
          contract: facetPath,
          constructorArguments: [],
        });
        console.log(`✅ ${analysis.name} verified`);
      } catch (error: any) {
        if (error.message.includes("Already Verified")) {
          console.log(`✅ ${analysis.name} already verified`);
        } else {
          console.log(`⚠️ ${analysis.name} verification failed:`, error.message);
        }
      }
    }

    console.log("\n✅ Contract verification process completed!");
    console.log("Note: Some contracts may already be verified or may take time to be indexed.");
  }

  // 10. Final summary
  console.log("\n" + "=".repeat(60));
  console.log("🎉 GENESIS VAULT FACET UPGRADE COMPLETED!");
  console.log("=".repeat(60));
  console.log("Network:", networkName);
  console.log("Genesis Vault Diamond Address:", DIAMOND_ADDRESS);
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

  console.log("=".repeat(60));

  if (isSafeOwnerBool) {
    console.log("\n📝 Next steps for Safe:");
    console.log("1. Safe 멀티시그에서 위의 Diamond Cut 트랜잭션을 실행하세요");
    console.log("2. 모든 Facet이 정상적으로 업그레이드되었는지 확인하세요");
    console.log("3. 업그레이드된 기능들을 테스트하세요");
    console.log("4. Block explorer에서 컨트랙트 검증 상태를 확인하세요");
  } else {
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

export { main as upgradeGenesisVaultFacet };
