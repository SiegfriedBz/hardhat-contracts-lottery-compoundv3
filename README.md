# Sample Hardhat Project

This project demonstrates a basic Hardhat use case. It comes with a sample contract, a test for that contract, and a script that deploys that contract.


// For running Staging tests on Goerli we need:
// 1. Get our SubId for ChainLink VRF
https://vrf.chain.link/
//// => GOERLI_LINK_SUBSCRIPTION_ID
// 2. Deploy our contract using the SubId
// -> yarn hardhat deploy --network goerli
// 3. Register the contract with ChainLink VRF & its SubId
// -> Set as VRF consumer the deployed contract address
// 4. Register the contract with ChainLink Keepers
https://automation.chain.link/
// 5. Run Staging Tests
// -> yarn hardhat test --network goerli

CHAINLINK GOERLI 0x326C977E6efc84E512bB9C30f76E30c160eD06FB



Try running some of the following tasks:

```shell
npx hardhat help
npx hardhat test
REPORT_GAS=true npx hardhat test
npx hardhat node
npx hardhat run scripts/deploy.js
```
