// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.15;

contract ConstPriceChainlinkOracle {
    int256 public immutable price;
    uint8 public immutable decimals;

    constructor(int256 price_, uint8 decimals_) {
        price = price_;
        decimals = decimals_;
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
        return (0, price, 0, block.timestamp, 0);
    }
}
