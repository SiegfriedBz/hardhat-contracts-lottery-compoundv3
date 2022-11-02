const { run } = require("hardhat")

async function verify(contractAddress, args) {
  console.log("Verifying contract...")
  try {
    await run("verify:verify", {
      address: contractAddress,
      constructorArguments: args,
    })
    console.log("Contract EtherScan Verification Successfull")
  } catch (error) {
    if (error.message.toLowerCase().includes("already verified")) {
      console.log("contract already verified")
    } else {
      console.log(error)
    }
  }
}

module.exports = {
  verify,
}
