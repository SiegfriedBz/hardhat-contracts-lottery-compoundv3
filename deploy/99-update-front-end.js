const { network, ethers } = require("hardhat")
const { networkConfig } = require("../hardhat-helper.config")
require("dotenv").config()
const fs = require("fs")

const chainId = network.config.chainId

// Lottery
const FRONT_END_ADDRESSES_LOTTERY_FILE =
  "../nextjs-lottery-with-compoundv3usdclending/constants/lottery/contractAddresses.json"
const FRONT_END_ABI_LOTTERY_FILE =
  "../nextjs-lottery-with-compoundv3usdclending/constants/lottery/contractAbi.json"

// Lottery Token
const FRONT_END_ADDRESSES_LOTTERY_TOKEN_FILE =
  "../nextjs-lottery-with-compoundv3usdclending/constants/lotteryToken/contractAddresses.json"
const FRONT_END_ABI_LOTTERY_TOKEN_FILE =
  "../nextjs-lottery-with-compoundv3usdclending/constants/lotteryToken/contractAbi.json"

// USDC
const FRONT_END_ADDRESSES_USDC_FILE =
  "../nextjs-lottery-with-compoundv3usdclending/constants/usdc/contractAddresses.json"
const FRONT_END_ABI_USDC_FILE =
  "../nextjs-lottery-with-compoundv3usdclending/constants/usdc/contractAbi.json"
const usdc_Address = networkConfig[chainId].usdc_Address

module.exports = async function () {
  if (process.env.UPDATE_FRONT_END) {
    console.log("updating front-end...")
    await updateContractAddresses()
    await updateAbi()
    console.log("Front-end updated.")
    console.log("-------------------------")
  }
}

async function updateAbi() {
  const lottery = await ethers.getContract("Lottery")
  fs.writeFileSync(
    FRONT_END_ABI_LOTTERY_FILE,
    lottery.interface.format(ethers.utils.FormatTypes.json)
  )

  const lotteryTokenAddress = await lottery.lotteryToken()
  const lotteryToken = await ethers.getContractAt(
    "LotteryToken",
    lotteryTokenAddress
  )
  fs.writeFileSync(
    FRONT_END_ABI_LOTTERY_TOKEN_FILE,
    lotteryToken.interface.format(ethers.utils.FormatTypes.json)
  )

  const usdc = await ethers.getContractAt("ERC20", usdc_Address)
  fs.writeFileSync(
    FRONT_END_ABI_USDC_FILE,
    usdc.interface.format(ethers.utils.FormatTypes.json)
  )
}

async function updateContractAddresses() {
  const chainId = network.config.chainId.toString()
  // Lottery
  const lottery = await ethers.getContract("Lottery")
  const currentAddressesLottery = JSON.parse(
    fs.readFileSync(FRONT_END_ADDRESSES_LOTTERY_FILE, "utf8")
  )
  if (chainId in currentAddressesLottery) {
    if (!currentAddressesLottery[chainId].includes(lottery.address)) {
      currentAddressesLottery[chainId].push(lottery.address)
    }
  } else {
    currentAddressesLottery[chainId] = [lottery.address]
  }
  fs.writeFileSync(
    FRONT_END_ADDRESSES_LOTTERY_FILE,
    JSON.stringify(currentAddressesLottery)
  )

  // Lottery Token
  const lotteryTokenAddress = await lottery.lotteryToken()
  const lotteryToken = await ethers.getContractAt(
    "LotteryToken",
    lotteryTokenAddress
  )
  const currentAddressesLotteryToken = JSON.parse(
    fs.readFileSync(FRONT_END_ADDRESSES_LOTTERY_TOKEN_FILE, "utf8")
  )
  if (chainId in currentAddressesLotteryToken) {
    if (!currentAddressesLotteryToken[chainId].includes(lotteryToken.address)) {
      currentAddressesLotteryToken[chainId].push(lotteryToken.address)
    }
  } else {
    currentAddressesLotteryToken[chainId] = [lotteryToken.address]
  }
  fs.writeFileSync(
    FRONT_END_ADDRESSES_LOTTERY_TOKEN_FILE,
    JSON.stringify(currentAddressesLotteryToken)
  )

  // USDC
  const usdc = await ethers.getContractAt("ERC20", usdc_Address)
  const currentAddressesUSDC = JSON.parse(
    fs.readFileSync(FRONT_END_ADDRESSES_USDC_FILE, "utf8")
  )
  if (chainId in currentAddressesUSDC) {
    if (!currentAddressesUSDC[chainId].includes(usdc.address)) {
      currentAddressesUSDC[chainId].push(usdc.address)
    }
  } else {
    currentAddressesUSDC[chainId] = [usdc.address]
  }
  fs.writeFileSync(
    FRONT_END_ADDRESSES_USDC_FILE,
    JSON.stringify(currentAddressesUSDC)
  )
}

module.exports.tags = ["all", "front-end"]
