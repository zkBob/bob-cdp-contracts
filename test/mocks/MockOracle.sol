pragma solidity ^0.8.0;

import "../../src/interfaces/oracles/IOracle.sol";
import "../utils/Utilities.sol";

contract MockOracle is IOracle, Utilities {
    mapping(address => uint256) prices;

    function setPrice(address token, uint256 newPrice) public {
        prices[token] = newPrice;
        if (token != usdc && newPrice != 0) {
            // align to USDC decimals
            makeDesiredUSDCPoolPrice(newPrice / 10**12, token);
        }
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
