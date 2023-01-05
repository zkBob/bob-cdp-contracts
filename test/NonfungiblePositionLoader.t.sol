// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/interfaces/external/univ3/INonfungiblePositionLoader.sol";
import "./SetupContract.sol";
import "./shared/ForkTests.sol";

contract NonfungiblePositionLoaderTest is Test, SetupContract, AbstractMainnetForkTest {
    INonfungiblePositionManager positionManager;
    uint256 tokenId = 1;

    constructor() {
        UniV3PositionManager = address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
        UniV3Factory = address(0x1F98431c8aD98523631AE4a59f267346ea31F984);
        SwapRouter = address(0xE592427A0AEce92De3Edee1F18E0157C05861564);

        wbtc = address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
        usdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        ape = address(0x4d224452801ACEd8B2F0aebE155379bb5D594381);

        chainlinkBtc = address(0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c);
        chainlinkUsdc = address(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
        chainlinkEth = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);

        tokens = [wbtc, usdc, weth];
        chainlinkOracles = [chainlinkBtc, chainlinkUsdc, chainlinkEth];
        heartbeats = [1500, 36000, 1500];
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
