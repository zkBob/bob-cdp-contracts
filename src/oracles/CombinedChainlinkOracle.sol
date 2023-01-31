// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.15;

import "../interfaces/external/chainlink/IAggregatorV3.sol";

contract CombinedChainlinkOracle {
    uint8 public decimals = 18;

    IAggregatorV3 public firstOracle;
    IAggregatorV3 public secondOracle;

    uint8 private overallDecimals;

    constructor(IAggregatorV3 firstOracle_, IAggregatorV3 secondOracle_) {
        overallDecimals = firstOracle.decimals() + secondOracle.decimals();
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

        answer = (overallDecimals < decimals)
            ? firstOracleAnswer * secondOracleAnswer * int256(10**(decimals - overallDecimals))
            : firstOracleAnswer * secondOracleAnswer / int256(10**(overallDecimals - decimals));

        return (
            0,
            answer,
            0,
            (firstOracleFallbackUpdatedAt < secondOracleFallbackUpdatedAt)
                ? firstOracleFallbackUpdatedAt
                : secondOracleFallbackUpdatedAt,
            0
        );
    }
}
