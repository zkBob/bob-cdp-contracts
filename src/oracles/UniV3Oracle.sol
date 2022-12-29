// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.13;

import "../interfaces/external/univ3/INonfungiblePositionManager.sol";
import "../interfaces/external/univ3/IUniswapV3Pool.sol";
import "../interfaces/external/univ3/IUniswapV3Factory.sol";
import "../interfaces/oracles/INFTOracle.sol";
import "../interfaces/oracles/IOracle.sol";
import "../libraries/external/FullMath.sol";
import "../libraries/external/LiquidityAmounts.sol";
import "../libraries/external/TickMath.sol";
import "../libraries/UniswapV3FeesCalculation.sol";
import "../proxy/EIP1967Admin.sol";

/// @notice Contract of the univ3 positions oracle
contract UniV3Oracle is INFTOracle {
    /// @notice Thrown when a given address is zero
    error AddressZero();

    /// @notice Thrown when no Chainlink oracle is added for one of tokens of a deposited Uniswap V3 NFT
    error MissingOracle();

    /// @notice Thrown when a tick deviation is out of limit
    error TickDeviation();

    /// @notice UniswapV3 position manager
    INonfungiblePositionManager public immutable positionManager;

    /// @notice UniswapV3 factory
    IUniswapV3Factory public immutable factory;

    /// @notice Oracle for price estimations
    IOracle public immutable oracle;

    uint256 public constant Q96 = 2**96;
    uint256 public constant Q48 = 2**48;

    /// @notice Creates a new contract
    /// @param positionManager_ UniswapV3 position manager
    /// @param oracle_ Oracle
    constructor(INonfungiblePositionManager positionManager_, IOracle oracle_) {
        if (address(positionManager_) == address(0)) {
            revert AddressZero();
        }

        positionManager = positionManager_;
        factory = IUniswapV3Factory(positionManager.factory());
        oracle = oracle_;
    }

    /// @inheritdoc INFTOracle
    function price(uint256 nft)
        external
        view
        returns (
            bool success,
            uint256 positionAmount,
            address pool
        )
    {
        (success, positionAmount, pool, ) = _price(nft);
    }

    /// @inheritdoc INFTOracle
    function checkPositionOnPossibleManipulation(uint256 nft, uint256 maxTickDeviation) external view {
        INonfungiblePositionManager.PositionInfo memory info = positionManager.positions(nft);

        IUniswapV3Pool pool = IUniswapV3Pool(factory.getPool(info.token0, info.token1, info.fee));

        uint256[2] memory tokenAmounts;
        uint256[2] memory pricesX96;
        bool[2] memory successOracle;

        (successOracle[0], pricesX96[0]) = oracle.price(info.token0);
        (successOracle[1], pricesX96[1]) = oracle.price(info.token1);

        if (!successOracle[0] || !successOracle[1]) {
            return;
        }

        (, int24 tick, , , , , ) = pool.slot0();

        uint160 chainlinkSqrtRatioX96 = uint160(FullMath.sqrt(FullMath.mulDiv(pricesX96[0], Q96, pricesX96[1])) * Q48);
        int24 chainlinkTick = TickMath.getTickAtSqrtRatio(chainlinkSqrtRatioX96);
        int24 tickDeviation = chainlinkTick - tick;
        uint24 absoluteTickDeviation = (tickDeviation < 0) ? uint24(-tickDeviation) : uint24(tickDeviation);

        if (absoluteTickDeviation > maxTickDeviation) {
            revert TickDeviation();
        }
    }

    /// @inheritdoc INFTOracle
    function safePrice(uint256 nft, uint256 maxTickDeviation)
        external
        view
        returns (
            bool success,
            uint256 positionAmount,
            address pool
        )
    {
        uint24 absoluteTickDeviation;
        (success, positionAmount, pool, absoluteTickDeviation) = _price(nft);
        if (absoluteTickDeviation > maxTickDeviation) {
            revert TickDeviation();
        }
    }

    function _price(uint256 nft)
        internal
        view
        returns (
            bool success,
            uint256 positionAmount,
            address pool,
            uint24 absoluteTickDeviation
        )
    {
        INonfungiblePositionManager.PositionInfo memory info = positionManager.positions(nft);

        pool = factory.getPool(info.token0, info.token1, info.fee);

        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(info.tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(info.tickUpper);

        uint256[2] memory tokenAmounts;
        uint256[2] memory pricesX96;
        {
            bool[2] memory successOracle;

            (successOracle[0], pricesX96[0]) = oracle.price(info.token0);
            (successOracle[1], pricesX96[1]) = oracle.price(info.token1);

            if (!successOracle[0] || !successOracle[1]) {
                return (false, 0, address(0), 0);
            }

            (uint160 sqrtRatioX96, int24 tick, , , , , ) = IUniswapV3Pool(pool).slot0();

            {
                uint160 chainlinkSqrtRatioX96 = uint160(
                    FullMath.sqrt(FullMath.mulDiv(pricesX96[0], Q96, pricesX96[1])) * Q48
                );
                int24 chainlinkTick = TickMath.getTickAtSqrtRatio(chainlinkSqrtRatioX96);
                int24 tickDeviation = chainlinkTick - tick;
                absoluteTickDeviation = (tickDeviation < 0) ? uint24(-tickDeviation) : uint24(tickDeviation);
            }

            (tokenAmounts[0], tokenAmounts[1]) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtRatioX96,
                sqrtRatioAX96,
                sqrtRatioBX96,
                info.liquidity
            );

            (uint256 actualTokensOwed0, uint256 actualTokensOwed1) = UniswapV3FeesCalculation._calculateUniswapFees(
                IUniswapV3Pool(pool),
                tick,
                info
            );
            tokenAmounts[0] += actualTokensOwed0;
            tokenAmounts[1] += actualTokensOwed1;
        }
        success = true;
        positionAmount = 0;
        for (uint256 i = 0; i < 2; ++i) {
            positionAmount += FullMath.mulDiv(tokenAmounts[i], pricesX96[i], Q96);
        }
    }
}
