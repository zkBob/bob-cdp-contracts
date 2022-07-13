// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.8.13;

import "./external/FullMath.sol";
import "../interfaces/external/univ3/IUniswapV3Pool.sol";

/// @title Math library for computing fees for uniswap v3 positions
library UniswapV3FeesCalculation {
    uint256 public constant Q128 = 2**128;

    /// @notice Additional information about UniV3 position
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @param liquidity The amount of liquidity owned by this position
    /// @param feeGrowthInside0LastX128 Fee growth of token0 inside the tick range as of the moment of the deposit
    /// @param feeGrowthInside1LastX128 Fee growth of token1 inside the tick range as of the moment of the deposit
    /// @param tokensOwed0 The computed amount of token0 owed to the position as of the moment of the deposit
    /// @param tokensOwed1 The computed amount of token1 owed to the position as of the moment of the deposit
    struct PositionInfo {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    /// @notice Calculate Uniswap token fees for the position with a given nft
    /// @param pool UniswapV3 pool
    /// @param tick The current tick for the position's pool
    /// @param positionInfo Additional position info
    /// @return actualTokensOwed0 The fees of the position in token0, actualTokensOwed1 The fees of the position in token1
    function _calculateUniswapFees(
        IUniswapV3Pool pool,
        int24 tick,
        PositionInfo memory positionInfo
    ) internal view returns (uint128 actualTokensOwed0, uint128 actualTokensOwed1) {
        actualTokensOwed0 = positionInfo.tokensOwed0;
        actualTokensOwed1 = positionInfo.tokensOwed1;

        if (positionInfo.liquidity == 0) {
            return (actualTokensOwed0, actualTokensOwed1);
        }

        uint256 feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128();
        uint256 feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128();

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = _getUniswapFeeGrowthInside(
            pool,
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

    /// @notice Get fee growth inside position from the tickLower to tickUpper since the pool has been initialised
    /// @param pool UniswapV3 pool
    /// @param tickLower UniswapV3 lower tick
    /// @param tickUpper UniswapV3 upper tick
    /// @param tickCurrent UniswapV3 current tick
    /// @param feeGrowthGlobal0X128 UniswapV3 fees of token0 collected per unit of liquidity for the entire life of the pool
    /// @param feeGrowthGlobal1X128 UniswapV3 fees of token1 collected per unit of liquidity for the entire life of the pool
    /// @return feeGrowthInside0X128 The all-time fee growth in token0, per unit of liquidity, inside the position's tick boundaries, feeGrowthInside1X128 The all-time fee growth in token1, per unit of liquidity, inside the position's tick boundaries
    function _getUniswapFeeGrowthInside(
        IUniswapV3Pool pool,
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        unchecked {
            (, , uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128, , , , ) = pool.ticks(
                tickLower
            );
            (, , uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128, , , , ) = pool.ticks(
                tickUpper
            );

            // calculate fee growth below
            uint256 feeGrowthBelow0X128;
            uint256 feeGrowthBelow1X128;
            if (tickCurrent >= tickLower) {
                feeGrowthBelow0X128 = lowerFeeGrowthOutside0X128;
                feeGrowthBelow1X128 = lowerFeeGrowthOutside1X128;
            } else {
                feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lowerFeeGrowthOutside0X128;
                feeGrowthBelow1X128 = feeGrowthGlobal1X128 - lowerFeeGrowthOutside1X128;
            }

            // calculate fee growth above
            uint256 feeGrowthAbove0X128;
            uint256 feeGrowthAbove1X128;
            if (tickCurrent < tickUpper) {
                feeGrowthAbove0X128 = upperFeeGrowthOutside0X128;
                feeGrowthAbove1X128 = upperFeeGrowthOutside1X128;
            } else {
                feeGrowthAbove0X128 = feeGrowthGlobal0X128 - upperFeeGrowthOutside0X128;
                feeGrowthAbove1X128 = feeGrowthGlobal1X128 - upperFeeGrowthOutside1X128;
            }

            feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
            feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;
        }
    }
}
