// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import "@quickswap/contracts/core/IAlgebraPool.sol";
import "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import "../interfaces/external/quickswapv3/INonfungiblePositionLoader.sol";
import "./UniswapV3FeesCalculation.sol";

/// @title Math library for computing fees for quickswap v3 positions
library QuickswapV3FeesCalculation {
    uint256 public constant Q128 = 2**128;

    /// @notice Calculate Uniswap token fees for the position with a given nft
    /// @param pool UniswapV3 pool
    /// @param tick The current tick for the position's pool
    /// @param positionInfo Additional position info
    /// @return actualTokensOwed0 The fees of the position in token0, actualTokensOwed1 The fees of the position in token1
    function _calculateQuickswapFees(
        IAlgebraPool pool,
        int24 tick,
        INonfungiblePositionLoader.PositionInfo memory positionInfo
    ) internal view returns (uint128 actualTokensOwed0, uint128 actualTokensOwed1) {
        actualTokensOwed0 = positionInfo.tokensOwed0;
        actualTokensOwed1 = positionInfo.tokensOwed1;

        if (positionInfo.liquidity == 0) {
            return (actualTokensOwed0, actualTokensOwed1);
        }

        uint256 feeGrowthGlobal0X128 = pool.totalFeeGrowth0Token();
        uint256 feeGrowthGlobal1X128 = pool.totalFeeGrowth1Token();

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = UniswapV3FeesCalculation
            ._getUniswapFeeGrowthInside(
                address(pool),
                positionInfo.tickLower,
                positionInfo.tickUpper,
                tick,
                feeGrowthGlobal0X128,
                feeGrowthGlobal1X128
            );

        uint256 feeGrowthInside0DeltaX128;
        uint256 feeGrowthInside1DeltaX128;
        unchecked {
            feeGrowthInside0DeltaX128 = feeGrowthInside0X128 - positionInfo.feeGrowthInside0LastX128;
            feeGrowthInside1DeltaX128 = feeGrowthInside1X128 - positionInfo.feeGrowthInside1LastX128;
        }

        actualTokensOwed0 += uint128(FullMath.mulDiv(feeGrowthInside0DeltaX128, positionInfo.liquidity, Q128));
        actualTokensOwed1 += uint128(FullMath.mulDiv(feeGrowthInside1DeltaX128, positionInfo.liquidity, Q128));
    }
}
