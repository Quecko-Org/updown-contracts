require("@nomicfoundation/hardhat-foundry");
require("@nomicfoundation/hardhat-ethers");
require("@nomicfoundation/hardhat-verify");
require("dotenv").config();

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.29",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      viaIR: true,
    },
  },
  networks: {
    // Default hardhat in-process network (used by `deploy:local`)
    hardhat: {},
    // Arbitrum Mainnet — requires ARBITRUM_RPC_URL + DEPLOYER_PRIVATE_KEY
    arbitrum: {
      url: process.env.ARBITRUM_RPC_URL || "",
      accounts: process.env.DEPLOYER_PRIVATE_KEY
        ? [`0x${process.env.DEPLOYER_PRIVATE_KEY.replace(/^0x/, "")}`]
        : [],
      chainId: 42161,
    },
  },
  etherscan: {
    apiKey: {
      arbitrumOne: process.env.ARBISCAN_API_KEY || "",
    },
  },
};
