// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;
import "forge-std/Script.sol";
import "../libraries/external/LiquidityAmounts.sol";
import "../libraries/external/FullMath.sol";
import "../libraries/external/TickMath.sol";

contract PriceDeviationTest is Script {
    uint256 constant Q96 = (1 << 96);
    uint256 constant Q48 = (1 << 48);

    uint256[] priceToken1X96 = [900, 990, 999, 1000, 1001, 1010, 1100];

    function targetSqrtRatioX96(uint256 priceToken0X96, uint256 priceToken1X96) public pure returns (uint160) {
        return uint160(FullMath.sqrt(FullMath.mulDiv(priceToken0X96, Q96, priceToken1X96)) * Q48);
    }

    function getCapital(
        uint128 liquidity,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 priceToken0X96,
        uint256 priceToken1X96
    ) public pure returns (uint256) {
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            targetSqrtRatioX96(priceToken0X96, priceToken1X96),
            sqrtRatioAX96,
            sqrtRatioBX96,
            liquidity
        );
        return FullMath.mulDiv(amount0, priceToken0X96, Q96) + FullMath.mulDiv(amount1, priceToken1X96, Q96);
    }

    function oneSample(
        uint128 liquidity,
        int24 leftTick,
        int24 rightTick,
        uint256 priceToken0X96,
        uint256 oldPriceToken1X96,
        uint256 newPriceToken1X96
    ) public view {
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(leftTick);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(rightTick);

        uint256 oldCapital = getCapital(liquidity, sqrtRatioAX96, sqrtRatioBX96, priceToken0X96, oldPriceToken1X96);
        uint256 newCapital = getCapital(liquidity, sqrtRatioAX96, sqrtRatioBX96, priceToken0X96, newPriceToken1X96);

        // capitalDelta = |newCapital / oldCapital - 1|
        uint256 capitalDeltaX96;
        if (oldCapital > newCapital) {
            capitalDeltaX96 = FullMath.mulDiv(oldCapital - newCapital, Q96, oldCapital);
        } else {
            capitalDeltaX96 = FullMath.mulDiv(newCapital - oldCapital, Q96, oldCapital);
        }

        // priceDelta = |newPrice / oldPrice - 1|
        uint256 priceDeltaX96;
        if (oldPriceToken1X96 > newPriceToken1X96) {
            priceDeltaX96 = FullMath.mulDiv(oldPriceToken1X96 - newPriceToken1X96, Q96, oldPriceToken1X96);
        } else {
            priceDeltaX96 = FullMath.mulDiv(newPriceToken1X96 - oldPriceToken1X96, Q96, oldPriceToken1X96);
        }

        require(capitalDeltaX96 <= priceDeltaX96);
    }

    function testSmallPosition() public view {
        for (uint256 i = 0; i < priceToken1X96.length; ++i) {
            for (uint256 j = 0; j < priceToken1X96.length; ++j) {
                if (j != i) {
                    oneSample(10**18, -100, 100, 1000 * Q96, priceToken1X96[i] * Q96, priceToken1X96[j] * Q96);
                    oneSample(10**18, -100, 0, 1000 * Q96, priceToken1X96[i] * Q96, priceToken1X96[j] * Q96);
                    oneSample(10**18, 0, 100, 1000 * Q96, priceToken1X96[i] * Q96, priceToken1X96[j] * Q96);
                }
            }
        }
    }

    function testLargePosition() public view {
        for (uint256 i = 0; i < priceToken1X96.length; ++i) {
            for (uint256 j = 0; j < priceToken1X96.length; ++j) {
                if (j != i) {
                    oneSample(10**18, -1000, 1000, 1000 * Q96, priceToken1X96[i] * Q96, priceToken1X96[j] * Q96);
                    oneSample(10**18, -1000, 0, 1000 * Q96, priceToken1X96[i] * Q96, priceToken1X96[j] * Q96);
                    oneSample(10**18, 0, 1000, 1000 * Q96, priceToken1X96[i] * Q96, priceToken1X96[j] * Q96);
                }
            }
        }
    }

    function run() external {
        testSmallPosition();
        testLargePosition();
    }
}
