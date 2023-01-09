// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.0;

interface INFTOracle {
    /// @notice Calculates the price of NFT position
    /// @param nft The token id of the position
    /// @return deviationSafety True if price deviation is safe, False otherwise
    /// @return positionAmount The value of the given position
    /// @return pool Address of the position's pool
    function price(uint256 nft)
        external
        view
        returns (
            bool deviationSafety,
            uint256 positionAmount,
            address pool
        );

    /// @notice Returns tokens for the NFT position
    /// @param nft The token id of the position
    /// @return token0 The token0 of the position
    /// @return token1 The token1 of the position
    function getPositionTokens(uint256 nft) external view returns (address token0, address token1);
}
