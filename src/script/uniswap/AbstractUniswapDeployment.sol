// SPDX-License-Identifier: CC0-1.0

pragma solidity ^0.8.0;

import "../../oracles/UniV3Oracle.sol";
import "../AbstractDeployment.sol";

abstract contract AbstractUniswapDeployment is AbstractDeployment {
    constructor() {
        amm = "uniswap";
    }

    function _deployOracle(
        address positionManager_,
        IOracle oracle_,
        uint256 maxPriceRatioDeviation_
    ) internal virtual override returns (INFTOracle oracle) {
        return new UniV3Oracle(positionManager_, oracle_, maxPriceRatioDeviation_);
    }

    function _getPool(
        address factory,
        address token0,
        address token1,
        uint256 fee
    ) internal view virtual override returns (address pool) {
        return IUniswapV3Factory(factory).getPool(token0, token1, uint24(fee));
    }
}
