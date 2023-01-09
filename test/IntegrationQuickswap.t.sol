// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./AbstractIntegration.t.sol";
import "./shared/AbstractQuickswapHelper.sol";

contract PolygonQuickswapIntegrationTestForVault is
    AbstractIntegrationTestForVault,
    AbstractPolygonForkTest,
    AbstractPolygonQuickswapConfigContract,
    PolygonQuickswapTestSuite
{}
