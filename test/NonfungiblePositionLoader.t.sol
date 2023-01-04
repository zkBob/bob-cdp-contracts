// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/interfaces/external/univ3/INonfungiblePositionLoader.sol";
import "./SetupContract.sol";
import "./utils/Utilities.sol";

contract NonfungiblePositionLoaderTest is Test, SetupContract, Utilities {
    INonfungiblePositionManager positionManager;
    uint256 tokenId = 3;

    function setUp() public {
        positionManager = INonfungiblePositionManager(UniV3PositionManager);
    }

    // integration scenarios

    function testPositionInfoGetter() public {
        INonfungiblePositionLoader.PositionInfo memory info = INonfungiblePositionLoader(address(positionManager))
            .positions(tokenId);

        (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = positionManager.positions(tokenId);

        assertEq(info.nonce, nonce);
        assertEq(info.operator, operator);
        assertEq(info.token0, token0);
        assertEq(info.token1, token1);
        assertEq(info.fee, fee);
        assertEq(info.tickLower, tickLower);
        assertEq(info.tickUpper, tickUpper);
        assertEq(info.liquidity, liquidity);
        assertEq(info.feeGrowthInside0LastX128, feeGrowthInside0LastX128);
        assertEq(info.feeGrowthInside1LastX128, feeGrowthInside1LastX128);
        assertEq(info.tokensOwed0, tokensOwed0);
        assertEq(info.tokensOwed1, tokensOwed1);
    }
}
