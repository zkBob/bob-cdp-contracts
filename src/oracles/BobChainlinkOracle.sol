// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.15;

contract BobChainlinkOracle {
    uint8 public decimals = 18;

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
        return (0, 10**18, 0, block.timestamp, 0);
    }
}
