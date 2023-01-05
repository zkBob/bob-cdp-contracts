// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/interfaces/external/univ3/INonfungiblePositionLoader.sol";
import "./SetupContract.sol";
import "./shared/ForkTests.sol";

contract NonfungiblePositionLoaderTest is Test, SetupContract, AbstractPolygonForkTest {
    INonfungiblePositionManager positionManager;
    uint256 tokenId = 1;

    constructor() {
        UniV3PositionManager = address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
        UniV3Factory = address(0x1F98431c8aD98523631AE4a59f267346ea31F984);
        SwapRouter = address(0xE592427A0AEce92De3Edee1F18E0157C05861564);

        wbtc = address(0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6);
        usdc = address(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);
        weth = address(0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619);
        ape = address(0xB7b31a6BC18e48888545CE79e83E06003bE70930);

        chainlinkBtc = address(0xc907E116054Ad103354f2D350FD2514433D57F6f);
        chainlinkUsdc = address(0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7);
        chainlinkEth = address(0xF9680D99D6C9589e2a93a78A04A279e509205945);

        tokens = [wbtc, usdc, weth];
        chainlinkOracles = [chainlinkBtc, chainlinkUsdc, chainlinkEth];
        heartbeats = [120, 120, 120];
    }

    function setUp() public {
        vm.createSelectFork(forkRpcUrl, forkBlock);
        positionManager = INonfungiblePositionManager(UniV3PositionManager);
    }

    function testPositionInfoGetter() public {
        INonfungiblePositionLoader.PositionInfo memory info = INonfungiblePositionLoader(address(positionManager))
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
