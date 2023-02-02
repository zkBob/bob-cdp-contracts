// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.15;

import "../interfaces/external/chainlink/IAggregatorV3.sol";

contract CombinedChainlinkOracle {
    uint8 public immutable decimals;
    int256 public immutable priceDenominator;

    IAggregatorV3 public immutable firstOracle;
    IAggregatorV3 public immutable secondOracle;

    constructor(IAggregatorV3 firstOracle_, IAggregatorV3 secondOracle_) {
        uint8 currentDecimals = firstOracle_.decimals() + secondOracle_.decimals();
        priceDenominator = (currentDecimals > 18) ? int256(10**(currentDecimals - 18)) : int256(1);
        decimals = (currentDecimals > 18) ? 18 : currentDecimals;

        firstOracle = firstOracle_;
        secondOracle = secondOracle_;
    }

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
