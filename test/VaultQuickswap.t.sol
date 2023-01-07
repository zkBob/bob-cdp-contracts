// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./AbstractVault.t.sol";
import "../src/oracles/QuickswapV3Oracle.sol";
import "./shared/AbstractQuickswapHelper.sol";

contract PolygonQuickswapVaultTest is
    AbstractVaultTest,
    AbstractPolygonForkTest,
    AbstractPolygonQuickswapConfigContract
{
    function _setUp() internal virtual override {
        PolygonQuickswapHelper helperImpl = new PolygonQuickswapHelper();
        helper = IHelper(address(helperImpl));

        MockOracle oracleImpl = new MockOracle();
        oracle = IMockOracle(address(oracleImpl));

        QuickswapV3Oracle nftOracleImpl = new QuickswapV3Oracle(PositionManager, IOracle(address(oracle)), 10**16);
        nftOracle = INFTOracle(address(nftOracleImpl));
    }
}
