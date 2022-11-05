const { ethers } = require("hardhat")
require("dotenv").config()

const networkConfig = {
  31337: {
    name: "hardhat",
    lotteryFee: ethers.utils.parseEther("0.001"), // 0.001 ETH
    lotteryTicketPrice: ethers.utils.parseUnits("10", 6), // 10 USDC
    initLTKAmount: ethers.utils.parseEther("10000"), // 10'000 LTK minted on deployment
    interval: "600",
    intervalWithdraw: "300",
    // link_VrfCoordinatorV2_Address will get itfrom Mock
    link_GasLane:
      "0x79d3d8832d904592c0bf9818b621522c988bb8b0c05cdc3b15aea1b6e8db0c15", // same as goerli
    // link_SubscriptionId : done programmatically, see 01-deploy-lottery.js
    link_baseFee: ethers.utils.parseEther("0.25"),
    link_gasPriceLink: 10e9,
    link_CallBack_GasLimit: 500000,
    usdc_Address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", // USDC Address on Main net https://docs.compound.finance/
    cometcUSDCv3_Address: "0xc3d688B66703497DAA19211EEdff47f25384cdc3", // cUSDCv3 on Main net
  },
  5: {
    name: "goerli",
    lotteryFee: ethers.utils.parseEther("0.001"), // 0.001 ETH
    lotteryTicketPrice: ethers.utils.parseUnits("10", 6), // 10 USDC
    initLTKAmount: ethers.utils.parseEther("10000"), // 10'000 LTK minted on deployment
    interval: "600",
    intervalWithdraw: "300",
    link_VrfCoordinatorV2_Address: "0x2Ca8E0C643bDe4C2E08ab1fA0da3401AdAD7734D",
    link_GasLane:
      "0x79d3d8832d904592c0bf9818b621522c988bb8b0c05cdc3b15aea1b6e8db0c15", // bytes32 _gasLane KeyHash
    link_SubscriptionId: "5772", // uint64 _subscriptionId,
    link_baseFee: ethers.utils.parseEther("0.25"), //it costs 0.25LINK per rdom number request// uint96 _baseFee : "Premium" value, network-specific at https://docs.chain.link/docs/vrf/v2/subscription/supported-networks/#goerli-testnet
    link_gasPriceLink: 10e9, // ~ LINK per GAS
    link_CallBack_GasLimit: "500000", // uint32 _callbackGasLimit
    usdc_Address: "0x07865c6E87B9F70255377e024ace6630C1Eaa37F", // USDC Address on goerli test net https://docs.compound.finance/
    cometcUSDCv3_Address: "0x3EE77595A8459e93C2888b13aDB354017B198188",
  },
}

developmentChains = ["hardhat", "localhost"]

module.exports = {
  networkConfig,
  developmentChains,
}
