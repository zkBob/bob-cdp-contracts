// SPDX-License-Identifier: UNLICENSED
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
        QuickswapV3Oracle nftOracle = new QuickswapV3Oracle(positionManager_, oracle_, maxPriceRatioDeviation_);
        return INFTOracle(address(nftOracle));
    }

    function _getPool(address token0, address token1) internal view virtual override returns (address pool) {
        return IAlgebraFactory(ammParams.factory).poolByPair(token0, token1);
    }
}
