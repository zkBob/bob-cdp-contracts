pragma solidity 0.8.13;

import "../../src/interfaces/oracles/IOracle.sol";

contract MockOracle is IOracle {
    mapping(address => uint256) prices;

    function setPrice(address token, uint256 newPrice) public {
        prices[token] = newPrice;
    }

    function price(address token) external view returns (bool success, uint256 priceX96) {
        success = true;
        priceX96 = prices[token];
    }

    function hasOracle(address token) external view returns (bool) {
        return (prices[token] > 0);
    }
}
