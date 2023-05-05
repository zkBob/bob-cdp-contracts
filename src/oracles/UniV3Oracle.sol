// SPDX-License-Identifier: CC0-1.0

pragma solidity 0.8.15;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "../interfaces/oracles/INFTOracle.sol";
import "../interfaces/oracles/IOracle.sol";
import "../libraries/UniswapV3FeesCalculation.sol";

/// @notice Contract of the univ3 positions oracle
contract UniV3Oracle is INFTOracle, Ownable {
    /// @notice Thrown when a given address is zero
    error AddressZero();

    /// @notice Thrown when no Chainlink oracle is added for one of tokens of a deposited Uniswap V3 NFT
    error MissingOracle();

    /// @notice UniswapV3 position manager
    INonfungiblePositionManager public immutable positionManager;

    /// @notice UniswapV3 factory
    IUniswapV3Factory public immutable factory;

    /// @notice Oracle for price estimations
    IOracle public immutable oracle;

    /// @notice Maximum price deviation allowed between oracle and univ3 pool
    uint256 public maxPriceRatioDeviation;

    uint256 public constant Q96 = 2**96;
    uint256 public constant Q48 = 2**48;

    /// @notice Creates a new contract
    /// @param positionManager_ UniswapV3 position manager
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

        positionManager = INonfungiblePositionManager(positionManager_);
        factory = IUniswapV3Factory(positionManager.factory());
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
        INonfungiblePositionLoader.PositionInfo memory info = INonfungiblePositionLoader(address(positionManager))
            .positions(nft);

        pool = factory.getPool(info.token0, info.token1, info.fee);

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

            (uint160 spotSqrtRatioX96, int24 tick, , , , , ) = IUniswapV3Pool(pool).slot0();
            uint256 ratioX96 = FullMath.mulDiv(pricesX96[0], Q96, pricesX96[1]);

            uint256 priceRatioX96 = FullMath.mulDiv(spotSqrtRatioX96, spotSqrtRatioX96, Q96);
            uint256 deviation;
            if (ratioX96 > priceRatioX96) {
                deviation = 1 ether - FullMath.mulDiv(priceRatioX96, 1 ether, ratioX96);
            } else {
                deviation = 1 ether - FullMath.mulDiv(ratioX96, 1 ether, priceRatioX96);
            }
            deviationSafety = deviation < maxPriceRatioDeviation;

            (tokenAmounts[0], tokenAmounts[1]) = LiquidityAmounts.getAmountsForLiquidity(
                uint160(Math.sqrt(ratioX96) * Q48),
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
        positionAmount =
            FullMath.mulDiv(tokenAmounts[0], pricesX96[0], Q96) +
            FullMath.mulDiv(tokenAmounts[1], pricesX96[1], Q96);
    }

    /// @notice Changes maxPriceRatioDeviation
    /// @param maxPriceRatioDeviation_ New maxPriceRatioDeviation
    function setMaxPriceRatioDeviation(uint256 maxPriceRatioDeviation_) external onlyOwner {
        maxPriceRatioDeviation = maxPriceRatioDeviation_;

        emit MaxPriceRatioDeviationChanged(msg.sender, maxPriceRatioDeviation_);
    }

    /// @inheritdoc INFTOracle
    function getPositionTokens(uint256 nft) external view returns (address token0, address token1) {
        INonfungiblePositionLoader.PositionInfo memory info = INonfungiblePositionLoader(address(positionManager))
            .positions(nft);
        return (info.token0, info.token1);
    }

    /// @notice Emitted when max price ratio deviation is updated
    /// @param sender Sender of the call (msg.sender)
    /// @param maxPriceRatioDeviation The new max price ratio deviation
    event MaxPriceRatioDeviationChanged(address indexed sender, uint256 maxPriceRatioDeviation);
}
