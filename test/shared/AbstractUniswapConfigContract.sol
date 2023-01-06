// SPDX-License-Identifier: CC0-1.0

pragma solidity ^0.8.0;

import "../mocks/interfaces/IMockOracle.sol";
import "../../src/interfaces/ICDP.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import "../../src/oracles/UniV3Oracle.sol";
import "./AbstractConfigContract.sol";
import "../mocks/MockOracle.sol";

abstract contract AbstractUniswapConfigContract is AbstractConfigSetupContract {
    function _setUp() internal virtual override {
        MockOracle oracleImpl = new MockOracle();
        oracle = IMockOracle(address(oracleImpl));

        UniV3Oracle nftOracleImpl = new UniV3Oracle(
            INonfungiblePositionManager(PositionManager),
            IOracle(address(oracle)),
            10**16
        );
        nftOracle = INFTOracle(address(nftOracleImpl));
    }

    function makeDesiredPoolPrice(
        uint256 targetPriceX96,
        address token0,
        address token1
    ) public virtual override {
        if (token0 > token1) {
            (token0, token1) = (token1, token0);
            targetPriceX96 = FullMath.mulDiv(Q96, Q96, targetPriceX96);
        }

        uint160 sqrtRatioX96 = uint160(Math.sqrt(targetPriceX96) * Q48);
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtRatioX96);
        IUniswapV3Pool pool = IUniswapV3Pool(IUniswapV3Factory(Factory).getPool(token0, token1, 3000));

        (, int24 currentPoolTick, , , , , ) = IUniswapV3Pool(pool).slot0();

        if (currentPoolTick < tick) {
            makeSwapManipulatePrice(token1, token0, sqrtRatioX96);
        } else {
            makeSwapManipulatePrice(token0, token1, sqrtRatioX96);
        }
        (, currentPoolTick, , , , , ) = IUniswapV3Pool(pool).slot0();
    }

    function makeDesiredUSDCPoolPrice(uint256 targetPriceX96, address token) public virtual override {
        makeDesiredPoolPrice(targetPriceX96, token, usdc);
    }

    function makeSwap(
        address token0,
        address token1,
        uint256 amount
    ) public virtual override returns (uint256 amountOut) {
        ISwapRouter swapRouter = ISwapRouter(SwapRouter);
        deal(token0, address(this), amount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: token0,
            tokenOut: token1,
            fee: 3000,
            recipient: address(this),
            deadline: type(uint256).max,
            amountIn: amount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        return swapRouter.exactInputSingle(params);
    }

    function makeSwapManipulatePrice(
        address token0,
        address token1,
        uint160 targetLimit
    ) public virtual override returns (uint256 amountOut) {
        ISwapRouter swapRouter = ISwapRouter(SwapRouter);
        address executor = getNextUserAddress();
        vm.startPrank(executor);
        deal(token0, executor, 10**40);
        IERC20(token0).approve(address(swapRouter), type(uint256).max);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: token0,
            tokenOut: token1,
            fee: 3000,
            recipient: executor,
            deadline: type(uint256).max,
            amountIn: 10**40,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: targetLimit
        });
        amountOut = swapRouter.exactInputSingle(params);
        vm.stopPrank();
    }

    function openPosition(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        address approveAddress
    ) public virtual override returns (uint256) {
        if (token0 > token1) {
            (token0, token1) = (token1, token0);
            (amount0, amount1) = (amount1, amount0);
        }

        INonfungiblePositionManager positionManager = INonfungiblePositionManager(PositionManager);
        IUniswapV3Pool pool = IUniswapV3Pool(IUniswapV3Factory(Factory).getPool(token0, token1, 3000));

        deal(token0, address(this), amount0 * 100);
        deal(token1, address(this), amount1 * 100);
        vm.deal(address(this), 1 ether);

        (, int24 currentTick, , , , , ) = pool.slot0();
        currentTick -= currentTick % 60;
        (uint256 tokenId, , , ) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: 3000,
                tickLower: currentTick - 600,
                tickUpper: currentTick + 600,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: type(uint256).max
            })
        );

        positionManager.approve(approveAddress, tokenId);
        return tokenId;
    }

    function setPools(ICDP vault) public virtual override {
        address[] memory pools = new address[](3);

        pools[0] = IUniswapV3Factory(Factory).getPool(wbtc, usdc, 3000);
        pools[1] = IUniswapV3Factory(Factory).getPool(weth, usdc, 3000);
        pools[2] = IUniswapV3Factory(Factory).getPool(wbtc, weth, 3000);

        for (uint256 i = 0; i < 3; ++i) {
            vault.setWhitelistedPool(pools[i]);
            vault.setLiquidationThreshold(pools[i], 6e8); // 0.6 * DENOMINATOR == 60%
        }
    }

    function getPool(address token0, address token1) public virtual override returns (address pool) {
        return IUniswapV3Factory(Factory).getPool(token0, token1, 3000);
    }

    function setTokenPrice(
        IMockOracle oracle,
        address token,
        uint256 newPrice
    ) public virtual override {
        oracle.setPrice(token, newPrice);
        if (token != usdc && newPrice != 0) {
            // align to USDC decimals
            makeDesiredUSDCPoolPrice(newPrice / 10**12, token);
        }
    }
}
