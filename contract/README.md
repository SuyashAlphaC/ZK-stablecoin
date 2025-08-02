
# ZK-Powered Decentralized Stablecoin (DSC)

## Overview

This project implements a decentralized, collateral-backed stablecoin named **Decentralized Stablecoin (DSC)**. The system is designed to maintain a 1:1 peg with the US Dollar.It is exogenously collateralized, meaning it is backed by external assets like Wrapped Ether (WETH) and Wrapped Bitcoin (WBTC).

A core feature of this protocol is the integration of **Zero-Knowledge (ZK) proofs** to verify user actions. Before any state-changing operation like minting DSC or redeeming collateral, the user must provide a ZK proof. This proof cryptographically attests that the user's position will remain healthy and over-collateralized *after* the transaction, without revealing any private details about their position. This shifts the computational load of health factor checks off-chain, leading to more efficient and private on-chain transactions.

## Core Contracts

### `DSCEngine.sol`
This is the heart of the system. The `DSCEngine` contract manages all core logic, including:

  - Depositing and redeeming collateral.
  - Minting and burning DSC tokens.
  -Interacting with the `HonkVerifier` to validate ZK proofs before executing transactions.

### `DecentralisedStableCoin.sol`
This is the ERC20 contract for the DSC token It includes standard token functionalities along with `mint` and `burn` functions that can only be called by the `DSCEngine`.

### `HonkVerifier.sol`
This contract serves as the on-chain verifier for the ZK proofs. When a user submits a proof to the `DSCEngine`, it is passed to this verifier, which returns `true` or `false` based on the proof's validity.

### `HelperConfig.s.sol`
A helper script used for deployment and testing that provides network-specific configuration details, such as the addresses for collateral tokens (WETH, WBTC) and their corresponding price feeds

-----

## How the ZK Proof System Works

The protocol ensures that the entire system remains over-collateralized by verifying every major action with a ZK proof. Here is a typical workflow for depositing collateral and minting DSC:

1.  **Off-Chain Proof Generation**: A user wants to deposit `10 WETH` as collateral and mint `1000 DSC`.Before sending the transaction, they use an off-chain script to generate a ZK proof. This proof attests to a public statement, such as: *"After depositing 10 WETH and minting 1000 DSC, my new total collateral value will be $X and my total minted DSC will be $Y, and the resulting health factor will be above the minimum requirement."*

2.  **On-Chain Transaction**: The user calls the `depositCollateralAndMintDscWithZK` function on the `DSCEngine` contract.They provide the collateral details, the mint amount, and the generated ZK proof with its public inputs.

3.  **On-Chain Verification**: The `DSCEngine` contract performs two checks:

      -It first calculates the expected collateral value and minted DSC amount on-chain.It requires that these on-chain values exactly match the public inputs provided by the user .
      -If they match, it forwards the proof and public inputs to the `i_verifier` contract.

4. **State Execution**: If the verifier confirms the proof is valid, the `DSCEngine` proceeds to accept the user's collateral and mint the requested DSC.If the proof is invalid or the public inputs do not match, the entire transaction reverts.

This same ZK-powered flow applies to other key operations like `redeemCollateralWithZK` and `burnDscWithZK`.

-----

## Key Functions in `DSCEngine.sol`

#### Minting & Depositing

  -`depositCollateralAndMintDscWithZK(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToMint, bytes memory proof`: Atomically deposits collateral and mints DSC after verifying a ZK proof.

#### Redeeming & Burning

  -`redeemCollateralForDscWithZK(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn, bytes memory proof)`: Atomically redeems collateral and burns DSC, contingent on a valid ZK proof.
  -`redeemCollateralWithZK(address tokenCollateralAddress, uint256 amountCollateral, bytes memory proof)`: Allows a user to withdraw collateral (if their position remains healthy) by providing a ZK proof.
  -`burnDscWithZK(uint256 amount, bytes memory proof)`: Burns DSC tokens to improve an account's health factor, verified by a ZK proof.

#### View Functions

  -`getAccountInformation(address user)`: Returns the total DSC minted and the total collateral value in USD for a specific user.
  -`getUsdValue(address token, uint256 amount)`: Returns the value of a given amount of collateral in USD, based on Chainlink price feeds.

-----

## Testing

The project is tested using the **Foundry** framework. The test suite (`DSCEngineTest.t.sol`) covers all major functionalities, including success cases and expected reverts.
To simulate the off-chain proof generation process during tests, Foundry's `vm.ffi()` cheatcode is used.This calls a JavaScript script (`js-scripts/generateProof.js`) that creates a valid proof based on the test inputs, which is then passed to the contract functions.

### Running Tests

To run the test suite, use the following command:

```bash
forge test
```