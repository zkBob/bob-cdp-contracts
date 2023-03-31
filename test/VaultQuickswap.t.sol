// SPDX-License-Identifier: CC0-1.0

pragma solidity ^0.8.0;

import "./AbstractVault.t.sol";
import "./shared/AbstractQuickswapHelper.sol";

contract PolygonQuickswapVaultTest is
    AbstractVaultTest,
    AbstractPolygonForkTest,
    AbstractPolygonQuickswapConfigContract,
    PolygonQuickswapTestSuite
{}
