import { HardhatUserConfig } from "hardhat/types";
import "@nomiclabs/hardhat-waffle";
import "@nomiclabs/hardhat-ethers";
import "@nomiclabs/hardhat-etherscan";
import "@openzeppelin/hardhat-upgrades";
import "hardhat-deploy";
import "hardhat-gas-reporter"
import "@typechain/hardhat"
import "hardhat-contract-sizer";
import "solidity-coverage";
import "hardhat-abi-exporter";

import { config as dotEnvConfig } from "dotenv";

dotEnvConfig();

const AVAX_MAINNET = 'https://api.avax.network/ext/bc/C/rpc'// 'http://18.159.49.69:9650/ext/bc/C/rpc' // 'https://api.avax.network/ext/bc/C/rpc'
const mnemonic = process.env.MNEMONIC || "";
const privateKey = process.env.GLACIER_DEPLOY_PRIVATE_KEY || "";

const defaultConfig = {
  accounts: { mnemonic },
}

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      // {
      //   version: "0.8.4",
      //   settings: {
      //     optimizer: {
      //       enabled: true,
      //       runs: 500,
      //     },
      //   }
      // },
      // {
      //   version: "0.8.6",
      //   settings: {
      //     optimizer: {
      //       enabled: true,
      //       runs: 500,
      //     },
      //   }
      // },
      // {
      //   version: "0.8.9",
      //   settings: {
      //     optimizer: {
      //       enabled: true,
      //       runs: 500,
      //     },
      //   }
      // },
      {
        version: "0.8.10",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        }
      }
    ]
  },
  defaultNetwork: "hardhat",
  networks: {
    localhost: {
      url: "http://127.0.0.1:8545"
    },
    hardhat: {
      chainId: 43114,
      forking: {
        url: AVAX_MAINNET,
        enabled: true,
        //blockNumber: 19773800
      },
      accounts: { 
        mnemonic: mnemonic
      },
    },
    avaxmainnet: {
      url: AVAX_MAINNET,
      gasPrice: 160000000000,
      accounts:
        privateKey !== undefined ? [privateKey] : [],
    },
    // avaxtestnet: {
    //   url: process.env.AVAX_TESTNET,
    //   accounts:
    //     privateKey !== undefined ? [privateKey] : [],
    // }
  },
  abiExporter: {
    path: './data/abi',
    runOnCompile: true,
    clear: true,
    flat: false,
    spacing: 2,
    pretty: false,
  },
  contractSizer: {
    alphaSort: true,
    disambiguatePaths: false,
    runOnCompile: true,
    strict: true,
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY,
  },
  typechain: {
    outDir: './typechain',
    target: 'ethers-v5',
    alwaysGenerateOverloads: false, // should overloads with full signatures like deposit(uint256) be generated always, even if there are no overloads?
  },
  gasReporter: {
      enabled: false
  }
};

export default config;