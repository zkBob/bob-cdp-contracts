// SPDX-License-Identifier: CC0-1.0

pragma solidity ^0.8.0;

import "./AbstractNftOracle.t.sol";
import "./shared/AbstractQuickswapHelper.sol";

contract NftOracleQuickswapTest is
    AbstractNftOracleTest,
    AbstractPolygonForkTest,
    AbstractPolygonQuickswapConfigContract,
    PolygonQuickswapTestSuite
{}
