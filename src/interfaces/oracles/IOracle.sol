// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IOracle {
    /// @notice Oracle price for tokens.
    /// @param token0 Reference to token0
    /// @param token1 Reference to token1
    /// @return priceX96 Price that satisfy tokens
    function price(
        address token0,
        address token1
    ) external view returns (uint256 priceX96);
}
