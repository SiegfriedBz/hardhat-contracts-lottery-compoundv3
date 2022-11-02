const { networkConfig, developmentChains } = require("../hardhat-helper.config")
const { network } = require("hardhat")

module.exports = async (hre) => {
  const { deployments, getNamedAccounts } = hre
  const { deploy, log } = deployments
  const { deployer } = await getNamedAccounts()
  const chainId = network.config.chainId

  const baseFee = networkConfig[chainId].link_baseFee // uint96 _baseFee see hardhat-helper-config
  const gasPriceLink = networkConfig[chainId].link_gasPriceLink // uint96 _gasPriceLink see hardhat-helper-config

  if (developmentChains.includes(network.name)) {
    console.log("Local network detected! Deploying mocks...")
    // deploy VRFCoordinatorV2 Mock
    await deploy("VRFCoordinatorV2Mock", {
      contract: "VRFCoordinatorV2Mock",
      from: deployer,
      args: [baseFee, gasPriceLink],
      log: true,
      waitConfirmations: 1,
    })
    console.log("Mocks deployed.")
    console.log("-------------------------")
  }
}

module.exports.tags = ["all", "mocks"]
