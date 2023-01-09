// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./shared/AbstractUniswapHelper.sol";
import "./AbstractVaultRegistry.t.sol";

contract MainnetUniswapVaultRegistryTest is
    AbstractVaultRegistryTest,
    AbstractMainnetForkTest,
    AbstractMainnetUniswapConfigContract,
    MainnetUniswapTestSuite
{}

contract PolygonUniswapVaultRegistryTest is
    AbstractVaultRegistryTest,
    AbstractPolygonForkTest,
    AbstractPolygonUniswapConfigContract,
    PolygonUniswapTestSuite
{}
