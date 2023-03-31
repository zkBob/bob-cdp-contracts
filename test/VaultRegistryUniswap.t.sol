// SPDX-License-Identifier: CC0-1.0

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
