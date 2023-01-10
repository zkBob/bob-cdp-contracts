// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./AbstractDeployment.sol";

abstract contract AbstractMainnetDeployment is AbstractDeployment {
    function tokens()
        public
        pure
        override
        returns (
            address wbtc,
            address weth,
            address usdc
        )
    {
        wbtc = address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
        weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        usdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    }

    function oracleParams()
        public
        pure
        override
        returns (
            address[] memory oracleTokens,
            address[] memory oracles,
            uint48[] memory heartbeats
        )
    {
        oracleTokens = new address[](3);

        oracleTokens[0] = address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599); // wbtc
        oracleTokens[1] = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // usdc
        oracleTokens[2] = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // weth

        oracles = new address[](3);

        oracles[0] = address(0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c); // btc
        oracles[1] = address(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6); // usdc
        oracles[2] = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419); // eth

        heartbeats = new uint48[](3);

        heartbeats[0] = 1500;
        heartbeats[1] = 36000;
        heartbeats[2] = 1500;
    }

    function vaultParams() public pure override returns (address treasury, uint256 stabilisationFee) {
        treasury = address(0x07883EbD6f178420f24969279BD425Ab0B99F10B);
        stabilisationFee = 10**7;
    }

    function targetToken() public pure override returns (address token) {
        token = address(0xB0B195aEFA3650A6908f15CdaC7D92F8a5791B0B);
    }
}
