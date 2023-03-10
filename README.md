# BOB Stablecoin - CDP Model Implementation

This repository contains the implementation of the Collateralized Debt Position (CDP) model for the BOB stablecoin. The CDP model allows users to collateralize their assets and generate BOB stablecoins against it, which can be used for various purposes such as trading, payments, and more.

## Repository Overview

This repository contains the smart contract implementation for the BOB CDP model. The CDP model allows users to deposit concentrate liquidity assets as a collateral such as positions from Uniswap V3 and Quickswap V3 and mint BOB stablecoins against it. Users can also withdraw their collateral and pay back their BOB stablecoins to close their CDP.

## Getting Started

Create `.env` file following `.env.example` for proper testing

Run `yarn test` if you set only `MAINNET_RPC`.

Run `yarn test:better` if you also set `ETHERSCAN_API_KEY`. This command allow showing readable trace for external contracts.

## References
- [zkbob-contract repository](https://github.com/zkBob/zkbob-contracts): BOB stablecoin smart contract implementation.
- [subgraph repository](https://github.com/zkBob/cdp-nft-subgraph): BOB CDP model the graph manifest implementation for data indexing.
- [liqbot repository](https://github.com/zkBob/cdp-nft-liqbot): BOB Liquidator Bot source code.
- [BOB Stablecoin documentation](https://docs.zkbob.com/bob-stablecoin/bob-highlights): Official documentation for the BOB stablecoin.

