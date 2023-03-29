// SPDX-License-Identifier: CC0-1.0

pragma solidity ^0.8.0;

import "./AbstractIntegration.t.sol";
import "./shared/AbstractUniswapHelper.sol";

contract MainnetUniswapIntegrationTestForVault is
    AbstractIntegrationTestForVault,
    AbstractMainnetForkTest,
    AbstractMainnetUniswapConfigContract,
    MainnetUniswapTestSuite
{}

contract PolygonUniswapIntegrationTestForVault is
    AbstractIntegrationTestForVault,
    AbstractPolygonForkTest,
    AbstractPolygonUniswapConfigContract,
    PolygonUniswapTestSuite
{}
