// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import "../../lib/forge-std/src/Script.sol";
import "../configs/PolygonConfigContract.sol";
import "forge-std/Vm.sol";
import "forge-std/console2.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "forge-std/Test.sol";
import "../../src/interfaces/external/univ3/IUniswapV3Pool.sol";
import "../../src/interfaces/external/univ3/ISwapRouter.sol";
import "../../src/interfaces/external/univ3/IUniswapV3Factory.sol";
import "../../src/interfaces/external/univ3/INonfungiblePositionManager.sol";
import "../../src/libraries/external/TickMath.sol";
import "../../src/libraries/external/FullMath.sol";

//common utilities for forge tests
contract Utilities is Test, PolygonConfigContract {
    bytes32 internal nextUser = keccak256(abi.encodePacked("user address"));

    uint256 public constant Q96 = 2**96;
    uint256 public constant Q48 = 2**48;

    function getNextUserAddress() public returns (address payable) {
        //bytes32 to address conversion
        address payable user = payable(address(uint160(uint256(nextUser))));
        nextUser = keccak256(abi.encodePacked(nextUser));
        return user;
    }

    //create users with 100 ether balance
    function createUsers(uint256 userNum) public returns (address payable[] memory) {
        address payable[] memory users = new address payable[](userNum);
        for (uint256 i = 0; i < userNum; i++) {
            address payable user = this.getNextUserAddress();
            vm.deal(user, 100 ether);
            users[i] = user;
        }
        return users;
    }

    //assert that two uints are approximately equal. tolerance in 1/10th of a percent
    function assertApproxEqual(
        uint256 expected,
        uint256 actual,
        uint256 tolerance
    ) public {
        uint256 leftBound = (expected * (1000 - tolerance)) / 1000;
        uint256 rightBound = (expected * (1000 + tolerance)) / 1000;
        assertTrue(leftBound <= actual && actual <= rightBound);
    }

    //move block.number forward by a given number of blocks
    function mineBlocks(uint256 numBlocks) public {
        uint256 targetBlock = block.number + numBlocks;
        vm.roll(targetBlock);
    }

    function getLength(address[] memory arr) public pure returns (uint256 len) {
        assembly {
            len := mload(add(arr, 0))
        }
    }

    function getLength(uint256[] memory arr) public pure returns (uint256 len) {
        assembly {
            len := mload(add(arr, 0))
        }
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

        uint160 sqrtRatioX96 = uint160(FullMath.sqrt(targetPriceX96) * Q48);
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtRatioX96);
        IUniswapV3Pool pool = IUniswapV3Pool(IUniswapV3Factory(UniV3Factory).getPool(token0, token1, 3000));

        (, int24 currentPoolTick, , , , , ) = IUniswapV3Pool(pool).slot0();

        if (currentPoolTick < tick) {
            makeSwapManipulatePrice(token1, token0, sqrtRatioX96);
        } else {
            makeSwapManipulatePrice(token0, token1, sqrtRatioX96);
        }
        (, currentPoolTick, , , , , ) = IUniswapV3Pool(pool).slot0();
    }

    function makeDesiredUSDCPoolPrice(uint256 targetPriceX96, address token) public {
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

    function openUniV3Position(
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

        INonfungiblePositionManager positionManager = INonfungiblePositionManager(UniV3PositionManager);
        IUniswapV3Pool pool = IUniswapV3Pool(IUniswapV3Factory(UniV3Factory).getPool(token0, token1, 3000));

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
}
