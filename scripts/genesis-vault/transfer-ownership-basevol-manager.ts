import { ethers, network } from "hardhat";
import input from "@inquirer/input";

/*
 npx hardhat run --network base_sepolia scripts/genesis-vault/transfer-ownership-basevol-manager.ts
 npx hardhat run --network base scripts/genesis-vault/transfer-ownership-basevol-manager.ts
*/

const NETWORK = ["base_sepolia", "base"] as const;
type SupportedNetwork = (typeof NETWORK)[number];

const DEFAULT_BASEVOL_MANAGER_ADDRESS = "0x47B72772c86C67ef9644Eb21b0531678aC886E72";
const DEFAULT_NEW_OWNER_ADDRESS = "";

const main = async () => {
  // Get network data from Hardhat config
  const networkName = network.name as SupportedNetwork;

  // Check if the network is supported
  if (!NETWORK.includes(networkName)) {
    throw new Error(`Network ${networkName} is not supported`);
  }

  console.log(`Transferring BaseVolManager ownership on ${networkName} network...`);

  // Get signer
  const [signer] = await ethers.getSigners();
  console.log("Current signer:", signer.address);

  // Get BaseVolManager address
  const baseVolManagerAddress = await input({
    message: "Enter the BaseVolManager proxy address",
    default: DEFAULT_BASEVOL_MANAGER_ADDRESS,
    validate: (val) => {
      if (!ethers.isAddress(val)) {
        return "Invalid address format";
      }
      if (val === ethers.ZeroAddress) {
        return "Address cannot be zero address";
      }
      return true;
    },
  });

  // Get new owner address
  const newOwnerAddress = await input({
    message: "Enter the new owner address",
    default: DEFAULT_NEW_OWNER_ADDRESS,
    validate: (val) => {
      if (!ethers.isAddress(val)) {
        return "Invalid address format";
      }
      if (val === ethers.ZeroAddress) {
        return "New owner address cannot be zero address";
      }
      if (val.toLowerCase() === signer.address.toLowerCase()) {
        return "New owner address cannot be the same as current signer";
      }
      return true;
    },
  });

  console.log("\n===========================================");
  console.log("Transfer Ownership Details:");
  console.log("===========================================");
  console.log("BaseVolManager Address:", baseVolManagerAddress);
  console.log("Current Owner (Signer):", signer.address);
  console.log("New Owner Address:", newOwnerAddress);
  console.log("Network:", networkName);
  console.log("===========================================");

  // Confirm before proceeding
  const confirm = await input({
    message: "Do you want to proceed with the ownership transfer? (yes/no)",
    default: "no",
    validate: (val) => {
      const lower = val.toLowerCase();
      if (lower !== "yes" && lower !== "no") {
        return "Please enter 'yes' or 'no'";
      }
      return true;
    },
  });

  if (confirm.toLowerCase() !== "yes") {
    console.log("Ownership transfer cancelled.");
    return;
  }

  try {
    // Get contract instance
    const BaseVolManager = await ethers.getContractAt("BaseVolManager", baseVolManagerAddress);

    // Check current owner
    const currentOwner = await BaseVolManager.owner();
    console.log("\nCurrent owner from contract:", currentOwner);

    if (currentOwner.toLowerCase() !== signer.address.toLowerCase()) {
      throw new Error(
        `Current signer (${signer.address}) is not the owner. Owner is ${currentOwner}`,
      );
    }

    // Transfer ownership
    console.log("\n🔄 Transferring ownership...");
    const tx = await BaseVolManager.transferOwnership(newOwnerAddress);
    console.log("Transaction hash:", tx.hash);

    console.log("Waiting for transaction confirmation...");
    const receipt = await tx.wait();

    if (receipt && receipt.status === 1) {
      console.log("✅ Ownership transfer completed successfully!");

      // Verify new owner
      const newOwner = await BaseVolManager.owner();
      console.log("\n===========================================");
      console.log("Ownership Transfer Summary:");
      console.log("===========================================");
      console.log("Previous Owner:", currentOwner);
      console.log("New Owner:", newOwner);
      console.log("Transaction Hash:", tx.hash);
      console.log("Block Number:", receipt.blockNumber);
      console.log("===========================================");

      if (newOwner.toLowerCase() === newOwnerAddress.toLowerCase()) {
        console.log("\n✅ Ownership verification successful!");
      } else {
        console.log("\n⚠️  Warning: New owner address mismatch!");
        console.log("Expected:", newOwnerAddress);
        console.log("Actual:", newOwner);
      }
    } else {
      throw new Error("Transaction failed");
    }
  } catch (error: any) {
    console.error("❌ Ownership transfer failed:", error);
    if (error.reason) {
      console.error("Reason:", error.reason);
    }
    if (error.code) {
      console.error("Error code:", error.code);
    }
    throw error;
  }
};

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
