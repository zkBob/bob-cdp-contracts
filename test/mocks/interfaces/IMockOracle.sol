// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../../src/interfaces/oracles/IOracle.sol";

interface IMockOracle is IOracle {
    function setPrice(address token, uint256 newPrice) external;
}
