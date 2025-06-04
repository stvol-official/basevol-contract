import "@nomicfoundation/hardhat-verify";
import "solidity-coverage";
import "@openzeppelin/hardhat-upgrades";
import "@typechain/hardhat";
import "@nomicfoundation/hardhat-ethers";
import "@nomicfoundation/hardhat-chai-matchers";

import * as fs from "fs";
import * as dotenv from "dotenv";

dotenv.config();

const mnemonic = fs.existsSync(".secret")
  ? fs.readFileSync(".secret").toString().trim()
  : "test test test test test test test test test test test junk";

// You need to export an object to set up your config
// Go to https://hardhat.org/config/ to learn more
export default {
  networks: {
    hardhat: {
      chainId: 31337,
    },
    localhost: {
      chainId: 31337,
    },
    base: {
      url: `https://mainnet.base.org`,
      gas: 22000000,
      allowUnlimitedContractSize: true,
      accounts: {
        mnemonic,
      },
      chainId: 8453,
    },
    base_sepolia: {
      url: `https://sepolia.base.org`,
      gas: 22000000,
      allowUnlimitedContractSize: true,
      accounts: {
        mnemonic,
      },
      chainId: 84532,
    },
  },
  solidity: {
    compilers: [
      {
        version: "0.8.20",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          viaIR: true,
        },
      },
      {
        version: "0.8.4",
        settings: {
          optimizer: {
            enabled: true,
            runs: 400,
          },
          viaIR: true,
        },
      },
    ],
  },
  typechain: {
    outDir: "typechain",
    target: "ethers-v6",
  },
  contractSizer: {
    alphaSort: true,
  },
  defaultNetwork: "hardhat",
  etherscan: {
    apiKey: {
      base: "QVZC44GURRCQ6YQTX79QSBDW6KBGG5C6CJ",
      baseSepolia: "QVZC44GURRCQ6YQTX79QSBDW6KBGG5C6CJ",
    },
    customChains: [
      {
        network: "base",
        chainId: 8453,
        urls: {
          apiURL: "https://api.basescan.org/api",
          browserURL: "https://basescan.org/",
        },
      },
      {
        network: "baseSepolia",
        chainId: 84532,
        urls: {
          apiURL: "https://api-sepolia.basescan.org/api",
          browserURL: "https://sepolia.basescan.org",
        },
      },
    ],
  },
  sourcify: {
    enabled: true,
  },
  abiExporter: {
    path: "./data/abi",
    clear: true,
    flat: false,
  },
};
