pragma solidity ^0.8.0;

import "./AbstractHelper.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract AbstractUniswapHelper is AbstractHelper {
    function getPool(address token0, address token1) public virtual override returns (address pool) {
        return IUniswapV3Factory(Factory).getPool(token0, token1, 3000);
    }

    function positions(uint256 nft) external returns (INonfungiblePositionLoader.PositionInfo memory) {
        return INonfungiblePositionLoader(PositionManager).positions(nft);
    }

    function makeDesiredPoolPrice(
        uint256 targetPriceX96,
        address token0,
        address token1
    ) public {
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

    function makeDesiredUSDCPoolPrice(uint256 targetPriceX96, address token) public override {
        makeDesiredPoolPrice(targetPriceX96, token, usdc);
    }

    function makeSwap(
        address token0,
        address token1,
        uint256 amount
    ) public returns (uint256 amountOut) {
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
    ) public returns (uint256 amountOut) {
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
    ) public returns (uint256) {
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

        positionManager.safeTransferFrom(address(this), msg.sender, tokenId, abi.encode(approveAddress));
        return tokenId;
    }
}

contract MainnetUniswapHelper is AbstractUniswapHelper, AbstractMainnetForkTest, AbstractMainnetUniswapConfigContract {}

contract PolygonUniswapHelper is AbstractUniswapHelper, AbstractPolygonForkTest, AbstractPolygonUniswapConfigContract {}
