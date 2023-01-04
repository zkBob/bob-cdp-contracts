pragma solidity 0.8.13;

import "../src/oracles/ChainlinkOracle.sol";
import "./configs/PolygonConfigContract.sol";
import "forge-std/Test.sol";
import "../src/interfaces/external/univ3/IUniswapV3Factory.sol";
import "../src/interfaces/external/univ3/IUniswapV3Pool.sol";
import "../src/proxy/EIP1967Proxy.sol";

import "forge-std/console2.sol";
import "../src/Vault.sol";

contract SetupContract is Test, PolygonConfigContract {
    function deployChainlink() internal returns (ChainlinkOracle) {
        ChainlinkOracle oracle = new ChainlinkOracle(tokens, chainlinkOracles, heartbeats, 3600);
        return oracle;
    }

    function setPools(ICDP vault) public {
        address[] memory pools = new address[](3);

        pools[0] = IUniswapV3Factory(UniV3Factory).getPool(wbtc, usdc, 3000);
        pools[1] = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        pools[2] = IUniswapV3Factory(UniV3Factory).getPool(wbtc, weth, 3000);

        for (uint256 i = 0; i < 3; ++i) {
            vault.setWhitelistedPool(pools[i]);
            vault.setLiquidationThreshold(pools[i], 6e8); // 0.6 * DENOMINATOR == 60%
        }
    }

    function setApprovals() public {
        IERC20(wbtc).approve(UniV3PositionManager, type(uint256).max);
        IERC20(weth).approve(UniV3PositionManager, type(uint256).max);
        IERC20(weth).approve(SwapRouter, type(uint256).max);
        IERC20(usdc).approve(SwapRouter, type(uint256).max);
        IERC20(usdc).approve(UniV3PositionManager, type(uint256).max);
        IERC20(ape).approve(UniV3PositionManager, type(uint256).max);
    }
}
