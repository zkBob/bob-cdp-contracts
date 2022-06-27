pragma solidity 0.8.13;

import "../../src/interfaces/oracles/IOracle.sol";

contract MockOracle is IOracle {
    mapping(address => uint256) prices;

    function setPrice(address token, uint256 newPrice) public {
        prices[token] = newPrice;
    }

    function price(address token) external view returns (uint256 priceX96) {
        priceX96 = prices[token];
    }
}
