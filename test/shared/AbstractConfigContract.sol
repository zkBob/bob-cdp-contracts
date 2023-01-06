// SPDX-License-Identifier: CC0-1.0

pragma solidity ^0.8.0;

import "../mocks/interfaces/IMockOracle.sol";
import "../../src/interfaces/ICDP.sol";
import "../../src/interfaces/oracles/INFTOracle.sol";
import "../SetupContract.sol";

abstract contract AbstractConfigContract is SetupContract {
    address PositionManager;
    address Factory;
    address SwapRouter;

    address wbtc;
    address usdc;
    address weth;
    address ape;

    address chainlinkBtc;
    address chainlinkUsdc;
    address chainlinkEth;

    address[] tokens;
    address[] chainlinkOracles;
    uint48[] heartbeats;

    INFTOracle nftOracle;
    IMockOracle oracle;
}

abstract contract AbstractConfigSetupContract is AbstractConfigContract {
    function _setUp() internal virtual {}

    function makeDesiredPoolPrice(
        uint256 targetPriceX96,
        address token0,
        address token1
    ) public virtual;

    function makeDesiredUSDCPoolPrice(uint256 targetPriceX96, address token) public virtual;

    function makeSwap(
        address token0,
        address token1,
        uint256 amount
    ) public virtual returns (uint256 amountOut);

    function makeSwapManipulatePrice(
        address token0,
        address token1,
        uint160 targetLimit
    ) public virtual returns (uint256 amountOut);

    function openPosition(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        address approveAddress
    ) public virtual returns (uint256);

    function setPools(ICDP vault) public virtual;

    function getPool(address token0, address token1) public virtual returns (address pool);

    function setTokenPrice(
        IMockOracle oracle,
        address token,
        uint256 newPrice
    ) public {
        oracle.setPrice(token, newPrice);
        if (token != usdc && newPrice != 0) {
            // align to USDC decimals
            makeDesiredUSDCPoolPrice(newPrice / 10**12, token);
        }
    }

    function setApprovals() public {
        IERC20(wbtc).approve(PositionManager, type(uint256).max);
        IERC20(weth).approve(PositionManager, type(uint256).max);
        IERC20(weth).approve(SwapRouter, type(uint256).max);
        IERC20(usdc).approve(SwapRouter, type(uint256).max);
        IERC20(usdc).approve(PositionManager, type(uint256).max);
        IERC20(ape).approve(PositionManager, type(uint256).max);
    }
}
