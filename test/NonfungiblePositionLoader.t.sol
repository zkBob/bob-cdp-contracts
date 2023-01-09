// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/interfaces/external/univ3/INonfungiblePositionLoader.sol";
import "./SetupContract.sol";
import "./shared/ForkTests.sol";

contract NonfungiblePositionLoaderTest is
    Test,
    SetupContract,
    AbstractPolygonForkTest,
    AbstractPolygonUniswapConfigContract
{
    uint256 tokenId = 1;

    function setUp() public {
        vm.createSelectFork(forkRpcUrl, forkBlock);
    }

    function testPositionInfoGetter() public {
        INonfungiblePositionLoader.PositionInfo memory info = INonfungiblePositionLoader(PositionManager)
            .positions(tokenId);

        // stack too deep :/
        // (...) = positionManager.positions(tokenId);

        assertEq(info.nonce, 0);
        assertEq(info.operator, address(0));
        assertEq(info.token0, address(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174));
        assertEq(info.token1, address(0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619));
        assertEq(info.fee, 3000);
        assertEq(info.tickLower, 193320);
        assertEq(info.tickUpper, 193620);
        assertEq(info.liquidity, 512574837727510);
        assertEq(info.feeGrowthInside0LastX128, 642091474819610939118051681932097);
        assertEq(info.feeGrowthInside1LastX128, 421246762958241140452438236726845208880797);
        assertEq(info.tokensOwed0, 0);
        assertEq(info.tokensOwed1, 0);
    }
}
