# Decentralized No Loss Lottery 

A sample Lottery contract with CompoundV3 USDC Lending

This contract is for creating an untamperable decentralized Lottery smart contract

This implements Chainlink oracles and CompoundV3
1. Chainlink VRF v2 to pick a random number
2. Chainlink Keeper to call the function to pick a Winner
3. CompoundV3 to lend USDC

Player can enter Lottery by:
1. transfering USDC to start lending
2. sending ETH to pay the Lottery

The deployment of the Lottery contract triggers the deployment of a ERC20 Lottery Token (LTK) contract.

Players get 1 LTK by entering Lottery (1 LTK / lottery ticket).
Player loose their LTK when they decide to withdraw (all) their initial USDC deposit.

The Winner of each Lottery round earns the interests accumulated during this round, by the whole Lottery USDC deposit.

```shell
yarn hardhat help
yarn hardhat deploy --network goerli
```
