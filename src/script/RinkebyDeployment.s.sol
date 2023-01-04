// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./AbstractDeployment.sol";

contract RinkebyDeployment is AbstractDeployment {
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
        wbtc = address(0x577D296678535e4903D59A4C929B718e1D575e0A);
        weth = address(0xc778417E063141139Fce010982780140Aa0cD5Ab);
        usdc = address(0x4DBCdF9B62e891a7cec5A2568C3F4FAF9E8Abe2b);
    }

    function oracleParams() public pure override returns (address[] memory oracleTokens, address[] memory oracles, uint48[] memory heartbeats) {
        oracleTokens = new address[](3);

        oracleTokens[0] = address(0x577D296678535e4903D59A4C929B718e1D575e0A); // wbtc
        oracleTokens[1] = address(0x4DBCdF9B62e891a7cec5A2568C3F4FAF9E8Abe2b); // usdc
        oracleTokens[2] = address(0xc778417E063141139Fce010982780140Aa0cD5Ab); // weth

        oracles = new address[](3);

        oracles[0] = address(0xECe365B379E1dD183B20fc5f022230C044d51404); // btc
        oracles[1] = address(0xa24de01df22b63d23Ebc1882a5E3d4ec0d907bFB); // usdc
        oracles[2] = address(0x8A753747A1Fa494EC906cE90E9f37563A8AF630e); // eth

        heartbeats = new uint48[](3);

        heartbeats[0] = 1500;
        heartbeats[1] = 36000;
        heartbeats[2] = 1500;
    }

    function vaultParams()
        public
        pure
        override
        returns (
            address positionManager,
            address factory,
            address treasury,
            uint256 stabilisationFee
        )
    {
        positionManager = address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
        factory = address(0x1F98431c8aD98523631AE4a59f267346ea31F984);
        treasury = address(0x07883EbD6f178420f24969279BD425Ab0B99F10B);
        stabilisationFee = 10**7;
    }

    function targetToken() public pure override returns (address token) {
        token = address(0xB0B195aEFA3650A6908f15CdaC7D92F8a5791B0B);
    }
}
