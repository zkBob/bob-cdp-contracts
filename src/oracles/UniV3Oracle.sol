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
import "@openzeppelin/contracts/access/Ownable.sol";

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

    /// @notice Creates a new contract
    /// @param positionManager_ UniswapV3 position manager
    /// @param oracle_ Oracle
    /// @param maxPriceRatioDeviation_ Maximum price deviation allowed between oracle and spot ticks
    constructor(
        INonfungiblePositionManager positionManager_,
        IOracle oracle_,
        uint256 maxPriceRatioDeviation_
    ) {
        if (address(positionManager_) == address(0)) {
            revert AddressZero();
        }

        positionManager = positionManager_;
        factory = IUniswapV3Factory(positionManager.factory());
        oracle = oracle_;
        maxPriceRatioDeviation = maxPriceRatioDeviation_;
    }

    /// @inheritdoc INFTOracle
    function price(uint256 nft)
        external
        view
        returns (
            bool success,
            bool deviationSafety,
            uint256 positionAmount,
            address pool
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
                return (false, true, 0, address(0));
            }

            (uint160 sqrtRatioX96, int24 tick, , , , , ) = IUniswapV3Pool(pool).slot0();

            {
                uint256 chainlinkPriceRatioX96 = FullMath.mulDiv(pricesX96[0], Q96, pricesX96[1]);
                uint256 priceRatioX96 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, Q96);
                uint256 deviation = FullMath.mulDiv(chainlinkPriceRatioX96, 1 ether, priceRatioX96);
                if (1 ether - maxPriceRatioDeviation < deviation && deviation < 1 ether + maxPriceRatioDeviation) {
                    deviationSafety = true;
                } else {
                    return (true, false, 0, address(0));
                }
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

    /// @notice Changes maxPriceRatioDeviation
    /// @param maxPriceRatioDeviation_ New maxPriceRatioDeviation
    function setMaxSqrtPriceX96Deviation(uint256 maxPriceRatioDeviation_) external onlyOwner {
        maxPriceRatioDeviation = maxPriceRatioDeviation_;
    }
}
