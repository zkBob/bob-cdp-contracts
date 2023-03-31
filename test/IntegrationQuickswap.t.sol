// SPDX-License-Identifier: CC0-1.0

pragma solidity ^0.8.0;

import "./AbstractIntegration.t.sol";
import "./shared/AbstractQuickswapHelper.sol";

contract PolygonQuickswapIntegrationTestForVault is
    AbstractIntegrationTestForVault,
    AbstractPolygonForkTest,
    AbstractPolygonQuickswapConfigContract,
    PolygonQuickswapTestSuite
{}
