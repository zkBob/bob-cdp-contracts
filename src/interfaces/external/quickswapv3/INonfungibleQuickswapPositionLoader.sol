// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface INonfungibleQuickswapPositionLoader {
    struct PositionInfo {
        uint96 nonce;
        address operator;
        address token0;
        address token1;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    function positions(uint256 tokenId) external view returns (PositionInfo memory);
}
