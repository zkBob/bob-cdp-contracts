// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.13;

interface INFTOracle {
    /// @notice Calculates the price of NFT position
    /// @param nft The token id of the position
    /// @return success True if call to an external oracle was successful, false otherwise
    /// @return positionAmount The value of the given position
    /// @return pool Address of the position's pool
    function price(uint256 nft)
        external
        view
        returns (
            bool success,
            uint256 positionAmount,
            address pool
        );

    /// @notice Checks position on possible price manipulation
    /// @param nft The token id of the position
    /// @param maxTickDeviation Maximum tick deviation allowed between oracle and spot ticks
    function checkPositionOnPossibleManipulation(uint256 nft, uint256 maxTickDeviation) external view;

    /// @notice Calculates the price of NFT position
    /// @param nft The token id of the position
    /// @param maxTickDeviation Maximum tick deviation allowed between oracle and spot ticks
    /// @return success True if call to an external oracle was successful, false otherwise
    /// @return positionAmount The value of the given position
    /// @return pool Address of the position's pool
    function safePrice(uint256 nft, uint256 maxTickDeviation)
        external
        view
        returns (
            bool success,
            uint256 positionAmount,
            address pool
        );
}
