// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../src/oracles/UniV3Oracle.sol";
import "./shared/AbstractUniswapHelper.sol";
import "./AbstractVaultRegistry.t.sol";

contract MainnetUniswapVaultRegistryTest is
    AbstractVaultRegistryTest,
    AbstractMainnetForkTest,
    AbstractMainnetUniswapConfigContract
{
    function _setUp() internal virtual override {
        MainnetUniswapHelper helperImpl = new MainnetUniswapHelper();
        helper = IHelper(address(helperImpl));

        MockOracle oracleImpl = new MockOracle();
        oracle = IMockOracle(address(oracleImpl));

        UniV3Oracle nftOracleImpl = new UniV3Oracle(PositionManager, IOracle(address(oracle)), 10**16);
        nftOracle = INFTOracle(address(nftOracleImpl));
    }
}

contract PolygonUniswapVaultRegistryTest is
    AbstractVaultRegistryTest,
    AbstractPolygonForkTest,
    AbstractPolygonUniswapConfigContract
{
    function _setUp() internal virtual override {
        PolygonUniswapHelper helperImpl = new PolygonUniswapHelper();
        helper = IHelper(address(helperImpl));

        MockOracle oracleImpl = new MockOracle();
        oracle = IMockOracle(address(oracleImpl));

        UniV3Oracle nftOracleImpl = new UniV3Oracle(PositionManager, IOracle(address(oracle)), 10**16);
        nftOracle = INFTOracle(address(nftOracleImpl));
    }
}
