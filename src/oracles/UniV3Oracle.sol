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
contract UniV3Oracle is EIP1967Admin, INFTOracle {
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

    uint256 public constant Q96 = 2**96;
    uint256 public constant Q48 = 2**48;

    /// @param positionManager_ UniswapV3 position manager
    /// @param factory_ UniswapV3 factory
    /// @param oracle_ Oracle
    constructor(
        INonfungiblePositionManager positionManager_,
        IUniswapV3Factory factory_,
        IOracle oracle_
    ) {
        if (address(positionManager_) == address(0) || address(factory_) == address(0)) {
            revert AddressZero();
        }

        positionManager = positionManager_;
        factory = factory_;
        oracle = oracle_;
    }

    function getPositionInfoByNft(uint256 nft)
        internal
        view
        returns (
            address,
            address,
            uint24,
            UniswapV3FeesCalculation.PositionInfo memory
        )
    {
        INonfungiblePositionManager.PositionInfo memory info = positionManager.positions(nft);

        UniswapV3FeesCalculation.PositionInfo memory positionInfo = UniswapV3FeesCalculation.PositionInfo({
            tickLower: info.tickLower,
            tickUpper: info.tickUpper,
            liquidity: info.liquidity,
            feeGrowthInside0LastX128: info.feeGrowthInside0LastX128,
            feeGrowthInside1LastX128: info.feeGrowthInside1LastX128,
            tokensOwed0: info.tokensOwed0,
            tokensOwed1: info.tokensOwed1
        });

        return (info.token0, info.token1, info.fee, positionInfo);
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
        (
            address token0,
            address token1,
            uint24 fee,
            UniswapV3FeesCalculation.PositionInfo memory positionInfo
        ) = getPositionInfoByNft(nft);

        pool = factory.getPool(token0, token1, fee);

        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(positionInfo.tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(positionInfo.tickUpper);

        uint256[] memory tokenAmounts = new uint256[](2);
        uint256[] memory pricesX96 = new uint256[](2);
        {
            bool[] memory successOracle = new bool[](2);

            (successOracle[0], pricesX96[0]) = oracle.price(token0);
            (successOracle[1], pricesX96[1]) = oracle.price(token1);

            if (!successOracle[0] || !successOracle[1]) {
                return (false, 0, address(0));
            }

            uint160 sqrtRatioX96 = uint160(FullMath.sqrt(FullMath.mulDiv(pricesX96[0], Q96, pricesX96[1])) * Q48);

            (, int24 tick, , , , , ) = IUniswapV3Pool(pool).slot0();

            (tokenAmounts[0], tokenAmounts[1]) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtRatioX96,
                sqrtRatioAX96,
                sqrtRatioBX96,
                positionInfo.liquidity
            );

            (uint256 actualTokensOwed0, uint256 actualTokensOwed1) = UniswapV3FeesCalculation._calculateUniswapFees(
                IUniswapV3Pool(pool),
                tick,
                positionInfo
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
