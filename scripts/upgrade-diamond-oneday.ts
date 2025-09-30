import { ethers, network, run } from "hardhat";
import input from "@inquirer/input";
import checkbox from "@inquirer/checkbox";

/*
 npx hardhat run --network base_sepolia scripts/upgrade-diamond-oneday.ts
 npx hardhat run --network base scripts/upgrade-diamond-oneday.ts
*/

const NETWORK = ["base_sepolia", "base"] as const;
type SupportedNetwork = (typeof NETWORK)[number];

const DIAMOND_ADDRESSES = {
  base_sepolia: "0x5382787eb91D48E934044c2D67B6A1A1381053a8", // Update after deployment
  base: "0x5B2eA3A959b525f95F80F29C0C52Cd9cC925DB74", // Update after deployment
};

const NETWORK_CONFIG = {
  base_sepolia: {
    chainId: 84532,
    blockExplorer: "https://sepolia.basescan.org",
    etherscanApiUrl: "https://api-sepolia.basescan.org/api",
    rpcUrl: "https://sepolia.base.org",
  },
  base: {
    chainId: 8453,
    blockExplorer: "https://basescan.org",
    etherscanApiUrl: "https://api.basescan.org/api",
    rpcUrl: "https://mainnet.base.org",
  },
};

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

interface FacetAnalysis {
  name: string;
  newSelectors: string[]; // Newly added functions
  existingSelectors: string[]; // Existing functions
  removedSelectors: string[]; // Removed functions
  cuts: FacetCut[]; // Cut operations to execute
  newFacetAddress: string;
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

async function analyzeFacet(
  facetInfo: { name: string; path: string },
  diamondAddress: string,
): Promise<FacetAnalysis> {
  console.log(`🔍 Analyzing ${facetInfo.name}...`);

  const FacetFactory = await ethers.getContractFactory(facetInfo.name);
  const newFacet = await FacetFactory.deploy();
  await newFacet.waitForDeployment();
  const newFacetAddress = await newFacet.getAddress();

  const newSelectors = getSelectors(await ethers.getContractAt(facetInfo.name, newFacetAddress));

  console.log(`📦 New ${facetInfo.name} deployed to: ${newFacetAddress}`);
  console.log(`🔢 New selectors (${newSelectors.length}): ${newSelectors.join(", ")}`);

  const diamondLoupe = await ethers.getContractAt("IDiamondLoupe", diamondAddress);
  const currentFacets = await diamondLoupe.facets();

  const existingSelectorsFromThisFacet: string[] = [];
  const removedSelectors: string[] = [];

  const currentSelectorToFacet = new Map<string, string>();
  for (const facet of currentFacets) {
    for (const selector of facet.functionSelectors) {
      currentSelectorToFacet.set(selector, facet.facetAddress);
    }
  }

  for (const selector of newSelectors) {
    if (currentSelectorToFacet.has(selector)) {
      existingSelectorsFromThisFacet.push(selector);
    }
  }

  const newSelectorsToAdd = newSelectors.filter(
    (selector) => !currentSelectorToFacet.has(selector),
  );

  console.log(
    `✅ Existing selectors (${existingSelectorsFromThisFacet.length}): ${existingSelectorsFromThisFacet.join(", ")}`,
  );
  console.log(
    `🆕 New selectors to add (${newSelectorsToAdd.length}): ${newSelectorsToAdd.join(", ")}`,
  );

  const cuts: FacetCut[] = [];

  if (existingSelectorsFromThisFacet.length > 0) {
    cuts.push({
      facetAddress: newFacetAddress,
      action: FacetCutAction.Replace,
      functionSelectors: existingSelectorsFromThisFacet,
    });
  }

  if (newSelectorsToAdd.length > 0) {
    cuts.push({
      facetAddress: newFacetAddress,
      action: FacetCutAction.Add,
      functionSelectors: newSelectorsToAdd,
    });
  }

  return {
    name: facetInfo.name,
    newFacetAddress,
    newSelectors: newSelectorsToAdd,
    existingSelectors: existingSelectorsFromThisFacet,
    removedSelectors,
    cuts,
  };
}

async function verifyContract(
  address: string,
  contractPath: string,
  networkName: SupportedNetwork,
  constructorArguments: any[] = [],
): Promise<boolean> {
  try {
    console.log(`🔍 Verifying contract at ${address}...`);

    await run("verify:verify", {
      address: address,
      contract: contractPath,
      constructorArguments: constructorArguments,
    });

    console.log(`✅ Contract verified successfully!`);
    return true;
  } catch (error: any) {
    console.log(`❌ Verification failed for ${address}`);

    if (
      error.message?.includes("Already Verified") ||
      error.message?.includes("already verified")
    ) {
      console.log(`ℹ️  Contract ${address} is already verified`);
      return true;
    }

    if (error.message?.includes("does not match")) {
      console.log(`⚠️  Source code mismatch for ${address}`);
      console.log(`   This might happen if the contract was compiled with different settings`);
    }

    if (error.message?.includes("API Key")) {
      console.log(`⚠️  API Key issue. Please check your hardhat.config.ts etherscan configuration`);
      console.log(`   For Base Sepolia, you need BASESCAN_API_KEY in your .env file`);
    }

    console.log(`   Error details: ${error.message}`);
    return false;
  }
}

const main = async () => {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name as SupportedNetwork;

  // Check if the network is supported.
  if (!NETWORK.includes(networkName)) {
    console.log(`Deploying to ${networkName} network is not supported...`);
    return;
  }

  console.log(`🚀 BaseVol OneDay Diamond Facet Upgrade Tool for ${networkName} network`);
  console.log("This tool automatically detects changes and applies appropriate actions");
  console.log("Configuration: 1 day interval, start timestamp: 1751356800 (2025-07-01 08:00:00)");

  const DIAMOND_ADDRESS = await input({
    message: "Enter the BaseVol OneDay Diamond contract address",
    default: DIAMOND_ADDRESSES[networkName] || "",
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
  console.log("Diamond Address:", DIAMOND_ADDRESS);
  console.log("Selected Facets:", selectedFacets.map((f: any) => f.name).join(", "));
  console.log("Configuration: OneDay (86400 seconds interval)");
  console.log("Safe Owner:", isSafeOwner.toUpperCase() === "Y" ? "Yes" : "No");
  console.log("Block Explorer:", NETWORK_CONFIG[networkName].blockExplorer);
  console.log("===========================================");

  await run("compile");
  console.log("✅ Compiled contracts...");

  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  console.log(`\n🔍 Analyzing ${selectedFacets.length} facet(s) for changes...\n`);

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
      console.log(`    Existing functions to update: ${analysis.existingSelectors.length}`);
      console.log(`   🗑️  Functions to remove: ${analysis.removedSelectors.length}`);
      console.log(`   ⚡ Cut operations: ${analysis.cuts.length}`);
      console.log(`    New facet address: ${analysis.newFacetAddress}\n`);
    } catch (error) {
      console.error(`❌ Error analyzing ${facet.name}:`, error);
      return;
    }
  }

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

  console.log("\n Total Changes:");
  console.log(`   🆕 New functions: ${totalNewFunctions}`);
  console.log(`    Updated functions: ${totalExistingFunctions}`);
  console.log(`   🗑️  Removed functions: ${totalRemovedFunctions}`);
  console.log(`   ⚡ Total cut operations: ${totalCuts.length}`);

  if (totalCuts.length === 0) {
    console.log("\n🎉 No changes detected! All facets are up to date.");
    return;
  }

  if (isSafeOwner.toUpperCase() === "Y") {
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
    console.log("1. https://safe.base.org/ 또는 https://safe.optimism.io/ 접속");
    console.log("2. 'New transaction' 클릭");
    console.log("3. 'Send tokens' 선택");
    console.log("4. 다음 정보를 입력:");
    console.log("   To:", DIAMOND_ADDRESS);
    console.log("   Value: 0");
    console.log("   Data:", data);
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

    for (const analysis of facetAnalyses) {
      if (analysis.cuts.length === 0) continue;

      console.log(`\nVerifying ${analysis.name}...`);
      await sleep(2000); // Rate limiting

      const facetInfo = AVAILABLE_FACETS.find((f) => f.name === analysis.name);
      if (facetInfo) {
        const success = await verifyContract(analysis.newFacetAddress, facetInfo.path, networkName);

        if (success) {
          console.log(
            `   ✅ ${analysis.name} verified on ${NETWORK_CONFIG[networkName].blockExplorer}`,
          );
        }
      }
    }
  } else {
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

    console.log(`\n⚡ Executing ${totalCuts.length} diamond cut operation(s)...`);

    console.log("Operations to be executed:");
    totalCuts.forEach((cut: any, index: number) => {
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

    const diamondCut = await ethers.getContractAt("IDiamondCut", DIAMOND_ADDRESS);

    const tx = await diamondCut.diamondCut(totalCuts, ethers.ZeroAddress, "0x");
    console.log("Diamond cut tx:", tx.hash);

    const receipt = await tx.wait();
    if (!receipt || receipt.status !== 1) {
      throw Error(`Diamond upgrade failed: ${tx.hash}`);
    }

    console.log("✅ Diamond cut completed successfully!");

    console.log("\n🔍 Verifying upgrades...");
    const diamondLoupe = await ethers.getContractAt("IDiamondLoupe", DIAMOND_ADDRESS);

    const maxRetries = 3;
    const retryDelay = 5000; // 5 seconds

    for (const analysis of facetAnalyses as FacetAnalysis[]) {
      if (analysis.cuts.length === 0) continue;

      console.log(`\n📋 Verifying ${analysis.name}...`);

      let verificationSuccess = false;
      let retryCount = 0;

      while (!verificationSuccess && retryCount < maxRetries) {
        try {
          const allSelectors = [...analysis.newSelectors, ...analysis.existingSelectors];
          let allSelectorsCorrect = true;

          for (const selector of allSelectors) {
            const facetAddress = await diamondLoupe.facetAddress(selector);

            if (facetAddress.toLowerCase() === analysis.newFacetAddress.toLowerCase()) {
              console.log(
                `   ✅ Selector ${selector} correctly points to new facet: ${analysis.newFacetAddress}`,
              );
            } else {
              console.log(`   ❌ Selector ${selector} verification failed!`);
              console.log(`      Expected: ${analysis.newFacetAddress}`);
              console.log(`      Actual: ${facetAddress}`);
              allSelectorsCorrect = false;
            }
          }

          if (allSelectorsCorrect) {
            verificationSuccess = true;
            console.log(`✅ ${analysis.name} verification completed successfully!`);
          } else {
            retryCount++;
            if (retryCount < maxRetries) {
              console.log(
                `⚠️  ${analysis.name} verification failed. Retrying in ${retryDelay / 1000} seconds... (${retryCount}/${maxRetries})`,
              );
              await sleep(retryDelay);
            } else {
              console.log(`❌ ${analysis.name} verification failed after ${maxRetries} attempts.`);
              console.log(`   This may indicate that the Diamond Cut was not executed properly.`);
              console.log(`   Please check the Diamond Cut transaction and try again.`);
            }
          }
        } catch (error) {
          retryCount++;
          console.log(
            `⚠️  Could not verify ${analysis.name} (attempt ${retryCount}/${maxRetries}):`,
            error,
          );
          if (retryCount < maxRetries) {
            await sleep(retryDelay);
          }
        }
      }
    }

    // 10. Function testing
    console.log("\n🧪 Testing upgraded facets...");
    for (const analysis of facetAnalyses) {
      if (analysis.cuts.length === 0) continue;

      console.log(`Testing ${analysis.name}...`);
      try {
        const facetContract = await ethers.getContractAt(analysis.name, DIAMOND_ADDRESS);
        console.log(`✅ ${analysis.name} functions are accessible`);
      } catch (error) {
        console.log(`⚠️  Could not test ${analysis.name} functions:`, error);
      }
    }

    // 11. Contract verification on block explorer
    console.log("\n🔍 Verifying contracts on block explorer...");

    // 블록 익스플로러 인덱싱을 위한 대기시간 증가
    console.log("⏳ Waiting for block explorer indexing...");
    await sleep(10000); // 10 seconds

    for (const analysis of facetAnalyses) {
      if (analysis.cuts.length === 0) continue;

      console.log(`\nVerifying ${analysis.name} contract...`);
      await sleep(3000); // Rate limiting between requests

      const facetInfo = AVAILABLE_FACETS.find((f) => f.name === analysis.name);
      if (facetInfo) {
        const success = await verifyContract(analysis.newFacetAddress, facetInfo.path, networkName);

        if (success) {
          console.log(
            `   ✅ ${analysis.name} verified on ${NETWORK_CONFIG[networkName].blockExplorer}`,
          );
          console.log(
            `   🔗 View at: ${NETWORK_CONFIG[networkName].blockExplorer}/address/${analysis.newFacetAddress}`,
          );
        }
      }

      // Rate limiting between verifications
      await sleep(2000);
    }
  }

  // 12. Final summary
  console.log("\n" + "=".repeat(60));
  console.log("🎉 BASEVOL ONEDAY DIAMOND FACET UPGRADE COMPLETED!");
  console.log("=".repeat(60));
  console.log("Network:", networkName);
  console.log("Diamond Address:", DIAMOND_ADDRESS);
  console.log(`Processed Facets: ${selectedFacets.length}`);
  console.log(`Total Operations: ${totalCuts.length}`);
  console.log("Safe Owner:", isSafeOwner.toUpperCase() === "Y" ? "Yes" : "No");

  console.log("\n📊 Changes Applied:");
  console.log(`   🆕 Functions added: ${totalNewFunctions}`);
  console.log(`    Functions updated: ${totalExistingFunctions}`);
  console.log(`   🗑️  Functions removed: ${totalRemovedFunctions}`);

  console.log("\n📦 Facet Details:");
  facetAnalyses.forEach((analysis, index) => {
    console.log(`  ${index + 1}. ${analysis.name}`);
    console.log(`     Address: ${analysis.newFacetAddress}`);
    console.log(`     Operations: ${analysis.cuts.length}`);
    console.log(
      `     Explorer: ${NETWORK_CONFIG[networkName].blockExplorer}/address/${analysis.newFacetAddress}`,
    );
  });

  console.log("=".repeat(60));

  if (isSafeOwner.toUpperCase() === "Y") {
    console.log("\n📝 Next steps for Safe:");
    console.log("1. Safe 멀티시그에서 위의 Diamond Cut 트랜잭션을 실행하세요");
    console.log("2. 모든 Facet이 정상적으로 업그레이드되었는지 확인하세요");
    console.log("3. 업그레이드된 기능들을 테스트하세요");
    console.log("4. Block explorer에서 컨트랙트 검증 상태를 확인하세요");
  } else {
    console.log("\n📋 Next steps:");
    console.log("1. Update your frontend if any function signatures changed");
    console.log("2. Test all upgraded facet functions thoroughly");
    console.log("3. Update documentation with new facet addresses");
    console.log("4. Monitor the system for any issues");
    console.log("5. Verify OneDay configuration (86400 seconds interval)");
    console.log("6. Check contract verification status on block explorer");
  }

  console.log("\n🔧 Troubleshooting tips for verification:");
  console.log("- Make sure BASESCAN_API_KEY is set in your .env file");
  console.log("- Check your hardhat.config.ts etherscan configuration");
  console.log("- Verification might take a few minutes to appear on the explorer");
  console.log(
    "- Manual verification can be done on the block explorer if automated verification fails",
  );
};

if (require.main === module) {
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}

export { main as upgradeDiamondOneday };
