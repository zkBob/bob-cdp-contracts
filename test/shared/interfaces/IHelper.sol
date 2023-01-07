// SPDX-License-Identifier: CC0-1.0

pragma solidity ^0.8.0;

import "../../mocks/interfaces/IMockOracle.sol";
import "../../../src/interfaces/ICDP.sol";

interface IHelper {
    function makeDesiredPoolPrice(
        uint256 targetPriceX96,
        address token0,
        address token1
    ) external;

    function makeDesiredUSDCPoolPrice(uint256 targetPriceX96, address token) external;

    function makeSwap(
        address token0,
        address token1,
        uint256 amount
    ) external returns (uint256 amountOut);

    function makeSwapManipulatePrice(
        address token0,
        address token1,
        uint160 targetLimit
    ) external returns (uint256 amountOut);

    function openPosition(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        address approveAddress
    ) external returns (uint256);

    function setTokenPrice(
        IMockOracle oracle,
        address token,
        uint256 newPrice
    ) external;

    function getPool(address token0, address token1) external returns (address pool);

    function setApprovals() external;

    function setPools(ICDP vault) external;
}
