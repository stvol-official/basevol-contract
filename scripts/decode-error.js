const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

/**
 * Decode custom error from error data
 * Usage: node scripts/decode-error.js <errorData> [contractName]
 * Example: node scripts/decode-error.js 0x2cdd6187
 * Example: node scripts/decode-error.js 0x2cdd6187 BaseVolStrike
 */

// Get all contract artifacts from artifacts directory
function getAllArtifacts() {
  const artifactsDir = path.join(__dirname, "../artifacts/contracts");
  const artifacts = [];

  function searchDir(dir) {
    if (!fs.existsSync(dir)) {
      return;
    }

    const files = fs.readdirSync(dir);

    for (const file of files) {
      const fullPath = path.join(dir, file);
      const stat = fs.statSync(fullPath);

      if (stat.isDirectory()) {
        searchDir(fullPath);
      } else if (file.endsWith(".json") && !file.endsWith(".dbg.json")) {
        try {
          const artifact = JSON.parse(fs.readFileSync(fullPath, "utf8"));
          if (artifact.abi && Array.isArray(artifact.abi)) {
            artifacts.push({
              name: artifact.contractName || file.replace(".json", ""),
              abi: artifact.abi,
              path: fullPath,
            });
          }
        } catch (e) {
          // Skip invalid JSON files
        }
      }
    }
  }

  searchDir(artifactsDir);
  return artifacts;
}

// Extract error selector (first 4 bytes) from error signature
function getErrorSelector(errorSignature) {
  return ethers.id(errorSignature).substring(0, 10);
}

// Find matching error in all contracts
function findError(errorData, contractNameFilter = null) {
  const selector = errorData.substring(0, 10).toLowerCase();
  const artifacts = getAllArtifacts();
  const matches = [];

  for (const artifact of artifacts) {
    // Skip if contract name filter is provided and doesn't match
    if (
      contractNameFilter &&
      !artifact.name.toLowerCase().includes(contractNameFilter.toLowerCase())
    ) {
      continue;
    }

    const errors = artifact.abi.filter((item) => item.type === "error");

    for (const error of errors) {
      const inputs = error.inputs || [];
      const inputTypes = inputs.map((input) => input.type).join(",");
      const errorSignature = `${error.name}(${inputTypes})`;
      const errorSelector = getErrorSelector(errorSignature);

      if (errorSelector.toLowerCase() === selector) {
        matches.push({
          contract: artifact.name,
          errorName: error.name,
          signature: errorSignature,
          selector: errorSelector,
          inputs: inputs,
          path: artifact.path,
        });
      }
    }
  }

  return matches;
}

// Decode error data with parameters
function decodeErrorData(errorData, errorInputs) {
  if (errorData.length <= 10) {
    return null; // No parameters
  }

  try {
    const paramData = "0x" + errorData.substring(10);
    const abiCoder = ethers.AbiCoder.defaultAbiCoder();
    const types = errorInputs.map((input) => input.type);
    const decoded = abiCoder.decode(types, paramData);

    return errorInputs.map((input, i) => ({
      name: input.name || `param${i}`,
      type: input.type,
      value: decoded[i].toString(),
    }));
  } catch (e) {
    return null;
  }
}

// Main function
function main() {
  const args = process.argv.slice(2);

  if (args.length === 0) {
    console.log("Usage: node scripts/decode-error.js <errorData> [contractName]");
    console.log("Example: node scripts/decode-error.js 0x2cdd6187");
    console.log("Example: node scripts/decode-error.js 0x2cdd6187 BaseVolStrike");
    process.exit(1);
  }

  const errorData = args[0];
  const contractNameFilter = args[1];

  if (!errorData.startsWith("0x")) {
    console.error("Error: errorData must start with '0x'");
    process.exit(1);
  }

  console.log("\n========================================");
  console.log("Custom Error Decoder");
  console.log("========================================\n");
  console.log(`Error Data: ${errorData}`);
  console.log(`Selector: ${errorData.substring(0, 10)}`);
  if (contractNameFilter) {
    console.log(`Filter: ${contractNameFilter}`);
  }
  console.log("");

  const matches = findError(errorData, contractNameFilter);

  if (matches.length === 0) {
    console.log("❌ No matching error found.");
    console.log("\nPossible reasons:");
    console.log("1. Contract not compiled (run: npm run compile)");
    console.log("2. Error is from external contract");
    console.log("3. Error selector is incorrect");
    process.exit(1);
  }

  console.log(`✅ Found ${matches.length} matching error(s):\n`);

  for (const match of matches) {
    console.log("----------------------------------------");
    console.log(`Contract: ${match.contract}`);
    console.log(`Error: ${match.errorName}`);
    console.log(`Signature: ${match.signature}`);
    console.log(`Selector: ${match.selector}`);

    if (match.inputs.length > 0) {
      console.log("\nParameters:");
      const decodedParams = decodeErrorData(errorData, match.inputs);

      if (decodedParams) {
        for (const param of decodedParams) {
          console.log(`  - ${param.name} (${param.type}): ${param.value}`);
        }
      } else {
        for (const input of match.inputs) {
          console.log(`  - ${input.name || "unnamed"} (${input.type})`);
        }
        console.log("\n⚠️  Could not decode parameter values");
      }
    } else {
      console.log("\nNo parameters");
    }

    console.log(`\nFile: ${match.path.replace(path.join(__dirname, ".."), ".")}`);
  }

  console.log("\n========================================\n");
}

// Run if called directly
if (require.main === module) {
  main();
}

module.exports = { findError, decodeErrorData, getErrorSelector };
