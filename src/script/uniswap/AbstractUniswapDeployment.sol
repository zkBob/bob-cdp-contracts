// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../../oracles/UniV3Oracle.sol";
import "../AbstractDeployment.sol";

abstract contract AbstractUniswapDeployment is AbstractDeployment {
    function _deployOracle(
        address positionManager_,
        IOracle oracle_,
        uint256 maxPriceRatioDeviation_
    ) internal virtual override returns (INFTOracle oracle) {
        UniV3Oracle nftOracle = new UniV3Oracle(positionManager_, oracle_, maxPriceRatioDeviation_);
        return INFTOracle(address(nftOracle));
    }

    function _getPool(address token0, address token1) internal view virtual override returns (address pool) {
        (, address factory) = ammParams();
        return IUniswapV3Factory(factory).getPool(token0, token1, 3000);
    }
}
