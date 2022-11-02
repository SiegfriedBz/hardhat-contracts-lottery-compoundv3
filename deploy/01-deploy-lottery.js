const { networkConfig, developmentChains } = require("../hardhat-helper.config")
const { network, ethers } = require("hardhat")
const { verify } = require("../utils/verify")
require("dotenv").config()

module.exports = async (hre) => {
  const { deployments, getNamedAccounts } = hre
  const { deploy, log } = deployments
  const { deployer } = await getNamedAccounts()
  const chainId = network.config.chainId

  /* Constructor args */
  // Lottery
  const lotteryFee = networkConfig[chainId].lotteryFee
  const lotteryTicketPrice = networkConfig[chainId].lotteryTicketPrice
  const interval = networkConfig[chainId].interval
  const intervalWithdraw = networkConfig[chainId].intervalWithdraw
  // Lottery Token
  const initLTKAmount = networkConfig[chainId].initLTKAmount
  // USDC
  const usdc_Address = networkConfig[chainId].usdc_Address
  // CompoundV3
  const cometcUSDCv3_Address = networkConfig[chainId].cometcUSDCv3_Address
  // Chainlink
  const link_GasLane = networkConfig[chainId].link_GasLane
  const link_CallBack_GasLimit = networkConfig[chainId].link_CallBack_GasLimit
  let link_VrfCoordinatorV2_Address
  let link_SubscriptionId

  let VRFCoordinatorV2Mock

  if (developmentChains.includes(network.name)) {
    // on local, get VRFCoordinatorV2 Mock
    VRFCoordinatorV2Mock = await ethers.getContract("VRFCoordinatorV2Mock")
    link_VrfCoordinatorV2_Address = VRFCoordinatorV2Mock.address
    const transactionResponse = await VRFCoordinatorV2Mock.createSubscription()
    const transactionReceipt = await transactionResponse.wait(1)
    // get link_SubscriptionId from event RandomWordsRequested emitted by VRFCoordinatorV2Mock
    link_SubscriptionId = transactionReceipt.events[0].args.subId
    // fund the subscription (done with LINK on real networks)
    await VRFCoordinatorV2Mock.fundSubscription(
      link_SubscriptionId,
      ethers.utils.parseEther("2")
    )
  } else {
    // on testnet
    link_VrfCoordinatorV2_Address =
      networkConfig[chainId].link_VrfCoordinatorV2_Address
    link_SubscriptionId = networkConfig[chainId].link_SubscriptionId // done from chainlink ui
    etherScanBaseUrl = networkConfig[chainId].etherScanBaseUrl
  }

  /* Constructor Args */
  let args = [
    lotteryFee,
    lotteryTicketPrice,
    interval,
    intervalWithdraw,
    link_VrfCoordinatorV2_Address,
    link_GasLane,
    link_SubscriptionId,
    link_CallBack_GasLimit,
    initLTKAmount,
    usdc_Address,
    cometcUSDCv3_Address,
  ]

  const lottery = await deploy("Lottery", {
    contract: "Lottery",
    from: deployer,
    args: args,
    log: true,
    waitConfirmations: network.config.blockConfirmations || 1,
  })
  console.log("Lottery deployed.")
  console.log("Admin: ", deployer)
  console.log("-------------------------")

  if (developmentChains.includes(network.name)) {
    // on local, add the lottery contract as a consumer of the VRFCoordinatorV2Mock
    await VRFCoordinatorV2Mock.addConsumer(link_SubscriptionId, lottery.address)
    console.log("Lottery added as a consumer of VRFCoordinatorV2Mock.")
    console.log("-------------------------")
  }

  if (
    // if deploy on testnet
    !developmentChains.includes(network.name) &&
    process.env.GOERLI_ETHERSCAN_API_KEY
  ) {
    console.log(
      "Etherscan goerli: ",
      `https://goerli.etherscan.io/address/${lottery.address}`
    )
    await verify(lottery.address, args)
  }
  console.log("-------------------------")
}

module.exports.tags = ["all", "lottery"]
