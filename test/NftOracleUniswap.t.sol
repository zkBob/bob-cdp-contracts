// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./AbstractNftOracle.sol";
import "./shared/AbstractUniswapHelper.sol";

contract NftOracleUniswapTest is
    AbstractNftOracleTest,
    AbstractPolygonForkTest,
    AbstractPolygonUniswapConfigContract,
    PolygonUniswapTestSuite
{}
