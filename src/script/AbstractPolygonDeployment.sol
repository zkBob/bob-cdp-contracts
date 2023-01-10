// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./AbstractDeployment.sol";

abstract contract AbstractPolygonDeployment is AbstractDeployment {
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
        wbtc = address(0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6);
        weth = address(0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619);
        usdc = address(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);
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

        oracleTokens[0] = address(0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6); // wbtc
        oracleTokens[1] = address(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174); // usdc
        oracleTokens[2] = address(0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619); // weth

        oracles = new address[](3);

        oracles[0] = address(0xc907E116054Ad103354f2D350FD2514433D57F6f); // btc
        oracles[1] = address(0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7); // usdc
        oracles[2] = address(0xF9680D99D6C9589e2a93a78A04A279e509205945); // eth

        heartbeats = new uint48[](3);

        heartbeats[0] = 120;
        heartbeats[1] = 120;
        heartbeats[2] = 120;
    }

    function vaultParams() public pure override returns (address treasury, uint256 stabilisationFee) {
        treasury = address(0x07883EbD6f178420f24969279BD425Ab0B99F10B);
        stabilisationFee = 10**7;
    }

    function targetToken() public pure override returns (address token) {
        token = address(0xB0B195aEFA3650A6908f15CdaC7D92F8a5791B0B);
    }
}
