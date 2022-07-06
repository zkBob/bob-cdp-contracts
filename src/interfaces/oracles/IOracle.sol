// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IOracle {
    /// @notice Oracle price for token.
    /// @param token Reference to token
    /// @return priceX96 Price that satisfies token
    function price(address token) external view returns (uint256 priceX96);
}
