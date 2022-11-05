# Decentralized No Loss Lottery 

A sample Lottery contract with CompoundV3 USDC Lending

This contract is for creating an untamperable decentralized Lottery smart contract

This implements Chainlink oracles and CompoundV3
1. Chainlink VRF v2 to pick a random number
2. Chainlink Keeper to call the function to pick a Winner
3. CompoundV3 to lend USDC

Player can enter Lottery by:
1. transfering USDC (lotteryTicketPrice) to start lending
2. sending ETH (lotteryFee) to pay the Lottery

Player gets 1 Lottery Token (LTK) by entering Lottery

The deployment of the Lottery contract triggers the deployment of ERC20 Lottery Token (LTK) contract.

```shell
yarn hardhat help
yarn hardhat deploy --network goerli
```
