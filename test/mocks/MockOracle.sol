pragma solidity ^0.8.0;

import "./interfaces/IMockOracle.sol";

contract MockOracle is IMockOracle {
    mapping(address => uint256) prices;

    function setPrice(address token, uint256 newPrice) external {
        prices[token] = newPrice;
    }

    function price(address token) external view returns (bool success, uint256 priceX96) {
        if (prices[token] == 0) {
            return (false, 0);
        }
        success = true;
        priceX96 = prices[token];
    }

    function hasOracle(address token) external view returns (bool) {
        return (prices[token] > 0);
    }
}
