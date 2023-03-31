// SPDX-License-Identifier: CC0-1.0

pragma solidity ^0.8.0;

import "../../oracles/QuickswapV3Oracle.sol";
import "../AbstractDeployment.sol";
import "@quickswap/core/IAlgebraFactory.sol";

abstract contract AbstractQuickswapDeployment is AbstractDeployment {
    constructor() {
        amm = "quickswap";
    }

    function _deployOracle(
        address positionManager_,
        IOracle oracle_,
        uint256 maxPriceRatioDeviation_
    ) internal virtual override returns (INFTOracle oracle) {
        return new QuickswapV3Oracle(positionManager_, oracle_, maxPriceRatioDeviation_);
    }

    function _getPool(
        address factory,
        address token0,
        address token1,
        uint256 fee
    ) internal view virtual override returns (address pool) {
        return IAlgebraFactory(factory).poolByPair(token0, token1);
    }
}
