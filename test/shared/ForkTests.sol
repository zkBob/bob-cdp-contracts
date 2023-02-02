// SPDX-License-Identifier: CC0-1.0

pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "./Env.sol";
import "./AbstractConfigContract.sol";

abstract contract AbstractForkTest is Test, AbstractConfigContract {
    string forkRpcUrl;
    uint256 forkBlock;
}

abstract contract AbstractLateSetup {
    function _setUp() internal virtual;
}

abstract contract AbstractMainnetForkTest is AbstractForkTest {
    constructor() {
        forkRpcUrl = forkRpcUrlMainnet;
        forkBlock = forkBlockMainnet;

        wbtc = address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
        usdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        dai = address(0x6B175474E89094C44Da98b954EedeAC495271d0F);
        bob = address(0xB0B195aEFA3650A6908f15CdaC7D92F8a5791B0B);

        chainlinkBtc = address(0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c);
        chainlinkUsdc = address(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
        chainlinkEth = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);

        tokens = [wbtc, usdc, weth];
        chainlinkOracles = [chainlinkBtc, chainlinkUsdc, chainlinkEth];
        heartbeats = [4000, 360000, 4000];
    }
}

abstract contract AbstractPolygonForkTest is AbstractForkTest {
    constructor() {
        forkRpcUrl = forkRpcUrlPolygon;
        forkBlock = forkBlockPolygon;

        wbtc = address(0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6);
        usdc = address(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);
        weth = address(0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619);
        dai = address(0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063);
        bob = address(0xB0B195aEFA3650A6908f15CdaC7D92F8a5791B0B);

        chainlinkBtc = address(0xc907E116054Ad103354f2D350FD2514433D57F6f);
        chainlinkUsdc = address(0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7);
        chainlinkEth = address(0xF9680D99D6C9589e2a93a78A04A279e509205945);

        tokens = [wbtc, usdc, weth];
        chainlinkOracles = [chainlinkBtc, chainlinkUsdc, chainlinkEth];
        heartbeats = [120, 120, 120];
    }
}
