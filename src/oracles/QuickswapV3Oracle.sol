// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.15;

import "../interfaces/oracles/INFTOracle.sol";
import "../interfaces/external/quickswapv3/INonfungibleQuickswapPositionLoader.sol";
import "../interfaces/oracles/IOracle.sol";
import "../libraries/QuickswapV3FeesCalculation.sol";
import {INonfungiblePositionManager as INonfungibleQuickswapPositionManager} from "@quickswap/periphery/INonfungiblePositionManager.sol";
import "@quickswap/core/IAlgebraFactory.sol";
import "@quickswap/core/IAlgebraPool.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Contract of the quickswap v3 positions oracle
contract QuickswapV3Oracle is INFTOracle, Ownable {
    /// @notice Thrown when a given address is zero
    error AddressZero();

    /// @notice Thrown when no Chainlink oracle is added for one of tokens of a deposited Quickswap V3 NFT
    error MissingOracle();

    /// @notice QuickswapV3 position manager
    INonfungibleQuickswapPositionManager public immutable positionManager;

    /// @notice QuickswapV3 factory
    IAlgebraFactory public immutable factory;

    /// @notice Oracle for price estimations
    IOracle public immutable oracle;

    /// @notice Maximum price deviation allowed between oracle and quickswap v3 pool
    uint256 public maxPriceRatioDeviation;

    uint256 public constant Q96 = 2**96;
    uint256 public constant Q48 = 2**48;

    /// @notice Creates a new contract
    /// @param positionManager_ QuickswapV3 position manager
    /// @param oracle_ Oracle
    /// @param maxPriceRatioDeviation_ Maximum price deviation allowed between oracle and spot ticks
    constructor(
        address positionManager_,
        IOracle oracle_,
        uint256 maxPriceRatioDeviation_
    ) {
        if (address(positionManager_) == address(0)) {
            revert AddressZero();
        }

        positionManager = INonfungibleQuickswapPositionManager(positionManager_);
        factory = IAlgebraFactory(positionManager.factory());
        oracle = oracle_;
        maxPriceRatioDeviation = maxPriceRatioDeviation_;
    }

    /// @inheritdoc INFTOracle
    function price(uint256 nft)
        external
        view
        returns (
            bool deviationSafety,
            uint256 positionAmount,
            uint24 width,
            address pool
        )
    {
        INonfungibleQuickswapPositionLoader.PositionInfo memory info = INonfungibleQuickswapPositionLoader(
            address(positionManager)
        ).positions(nft);

        pool = factory.poolByPair(info.token0, info.token1);

        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(info.tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(info.tickUpper);
        width = uint24(info.tickUpper - info.tickLower);

        uint256[2] memory tokenAmounts;
        uint256[2] memory pricesX96;
        {
            bool[2] memory successOracle;

            (successOracle[0], pricesX96[0]) = oracle.price(info.token0);
            (successOracle[1], pricesX96[1]) = oracle.price(info.token1);

            if (!successOracle[0] || !successOracle[1]) {
                revert MissingOracle();
            }

            (uint160 spotSqrtRatioX96, int24 tick, , , , , ) = IAlgebraPool(pool).globalState();
            uint256 ratioX96 = FullMath.mulDiv(pricesX96[0], Q96, pricesX96[1]);

            {
                uint256 priceRatioX96 = FullMath.mulDiv(spotSqrtRatioX96, spotSqrtRatioX96, Q96);
                uint256 deviation = FullMath.mulDiv(ratioX96, 1 ether, priceRatioX96);
                if (1 ether - maxPriceRatioDeviation < deviation && deviation < 1 ether + maxPriceRatioDeviation) {
                    deviationSafety = true;
                } else {
                    deviationSafety = false;
                }
            }

            (tokenAmounts[0], tokenAmounts[1]) = LiquidityAmounts.getAmountsForLiquidity(
                uint160(Math.sqrt(ratioX96) * Q48),
                sqrtRatioAX96,
                sqrtRatioBX96,
                info.liquidity
            );

            (uint256 actualTokensOwed0, uint256 actualTokensOwed1) = QuickswapV3FeesCalculation._calculateQuickswapFees(
                IAlgebraPool(pool),
                tick,
                info
            );
            tokenAmounts[0] += actualTokensOwed0;
            tokenAmounts[1] += actualTokensOwed1;
        }
        positionAmount = 0;
        for (uint256 i = 0; i < 2; ++i) {
            positionAmount += FullMath.mulDiv(tokenAmounts[i], pricesX96[i], Q96);
        }
    }

    /// @inheritdoc INFTOracle
    function getPositionTokens(uint256 nft) external view returns (address token0, address token1) {
        INonfungibleQuickswapPositionLoader.PositionInfo memory info = INonfungibleQuickswapPositionLoader(
            address(positionManager)
        ).positions(nft);
        return (info.token0, info.token1);
    }
}
