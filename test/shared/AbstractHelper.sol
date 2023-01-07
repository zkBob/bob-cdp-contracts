import "./interfaces/IHelper.sol";
import "./ForkTests.sol";
import "../../src/interfaces/ICDP.sol";
import "../mocks/interfaces/IMockOracle.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../SetupContract.sol";

import "forge-std/console2.sol";

abstract contract AbstractHelper is IHelper, AbstractForkTest, SetupContract {
    function setPools(ICDP vault) public {
        address[] memory pools = new address[](3);

        pools[0] = getPool(wbtc, usdc);
        pools[1] = getPool(weth, usdc);
        pools[2] = getPool(wbtc, weth);

        for (uint256 i = 0; i < 3; ++i) {
            vault.setWhitelistedPool(pools[i]);
            vault.setLiquidationThreshold(pools[i], 6e8); // 0.6 * DENOMINATOR == 60%
        }
    }

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

    function makeDesiredUSDCPoolPrice(uint256 targetPriceX96, address token) public virtual;

    function getPool(address token0, address token1) public virtual returns (address pool);

    function setApprovals() public {
        IERC20(wbtc).approve(PositionManager, type(uint256).max);
        IERC20(weth).approve(PositionManager, type(uint256).max);
        IERC20(weth).approve(SwapRouter, type(uint256).max);
        IERC20(usdc).approve(SwapRouter, type(uint256).max);
        IERC20(usdc).approve(PositionManager, type(uint256).max);
        IERC20(ape).approve(PositionManager, type(uint256).max);
    }
}
