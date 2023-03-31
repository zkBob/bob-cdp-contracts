// SPDX-License-Identifier: CC0-1.0

pragma solidity 0.8.15;

import "../interfaces/external/chainlink/IAggregatorV3.sol";

/// @notice Contract that multiplies results of two chainlink oracles (i.e. WSTETH/STETH & STETH/USD)
contract CombinedChainlinkOracle {
    /// @notice Price's decimals
    uint8 public immutable decimals;

    /// @notice Denominator of multiply result
    int256 public immutable priceDenominator;

    /// @notice First Chainlink oracle
    IAggregatorV3 public immutable firstOracle;

    /// @notice Second Chainlink oracle
    IAggregatorV3 public immutable secondOracle;

    /// @notice Creates a new contract
    /// @param firstOracle_ First Chainlink Oracle
    /// @param secondOracle_ Second Chainlink Oracle
    constructor(IAggregatorV3 firstOracle_, IAggregatorV3 secondOracle_) {
        uint8 currentDecimals = firstOracle_.decimals() + secondOracle_.decimals();
        priceDenominator = (currentDecimals > 18) ? int256(10**(currentDecimals - 18)) : int256(1);
        decimals = (currentDecimals > 18) ? 18 : currentDecimals;

        firstOracle = firstOracle_;
        secondOracle = secondOracle_;
    }

    /// @notice Returns chainlink oracle compatible price data
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        (, int256 firstOracleAnswer, , uint256 firstOracleFallbackUpdatedAt, ) = firstOracle.latestRoundData();
        (, int256 secondOracleAnswer, , uint256 secondOracleFallbackUpdatedAt, ) = secondOracle.latestRoundData();

        return (
            0,
            (firstOracleAnswer * secondOracleAnswer) / priceDenominator,
            0,
            (firstOracleFallbackUpdatedAt < secondOracleFallbackUpdatedAt)
                ? firstOracleFallbackUpdatedAt
                : secondOracleFallbackUpdatedAt,
            0
        );
    }
}
