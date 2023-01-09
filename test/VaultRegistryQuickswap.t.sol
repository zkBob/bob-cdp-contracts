// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./shared/AbstractQuickswapHelper.sol";
import "./AbstractVaultRegistry.t.sol";

contract PolygonQuickswapVaultRegistryTest is
    AbstractVaultRegistryTest,
    AbstractPolygonForkTest,
    AbstractPolygonQuickswapConfigContract,
    PolygonQuickswapTestSuite
{}
