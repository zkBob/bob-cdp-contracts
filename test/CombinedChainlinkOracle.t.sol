import "./SetupContract.sol";
import "./shared/AbstractConfigContract.sol";
import "./shared/ForkTests.sol";
import "../src/oracles/ConstPriceChainlinkOracle.sol";
import "../src/oracles/CombinedChainlinkOracle.sol";
import "../src/oracles/ChainlinkOracle.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "./shared/AbstractUniswapHelper.sol";

contract CombinedChainlinkOracleTest is
    Test,
    SetupContract,
    AbstractMainnetForkTest,
    AbstractMainnetUniswapConfigContract
{
    function setUp() public {
        vm.createSelectFork(forkRpcUrl, forkBlock);
    }

    function testCombinedChainlinkOracle() public {
        ConstPriceChainlinkOracle firstChainlinkOracle = new ConstPriceChainlinkOracle(1 ether, 8);
        ConstPriceChainlinkOracle secondChainlinkOracle = new ConstPriceChainlinkOracle(2 ether, 10);
        CombinedChainlinkOracle combinedOracle = new CombinedChainlinkOracle(
            IAggregatorV3(address(firstChainlinkOracle)),
            IAggregatorV3(address(secondChainlinkOracle))
        );
        assertEq(combinedOracle.decimals(), 18);
        (, int256 answer, , uint256 updatedAt, ) = combinedOracle.latestRoundData();
        assertEq(answer, 2 * 10**36);
        assertEq(updatedAt, block.timestamp);
    }

    function testCombinedChainlinkOracleReturnsEarliestUpdatedAt() public {
        ConstPriceChainlinkOracle firstChainlinkOracle = new ConstPriceChainlinkOracle(1 ether, 8);
        CombinedChainlinkOracle combinedOracle = new CombinedChainlinkOracle(
            IAggregatorV3(address(firstChainlinkOracle)),
            IAggregatorV3(chainlinkBtc)
        );
        assertEq(combinedOracle.decimals(), 16);
        (, int256 btcAnswer, , uint256 btcUpdatedAt, ) = IAggregatorV3(chainlinkBtc).latestRoundData();
        (, int256 answer, , uint256 updatedAt, ) = combinedOracle.latestRoundData();
        assertEq(answer, btcAnswer * 10**18);
        assertEq(updatedAt, btcUpdatedAt);
    }

    function testCombinedChainlinkOracleWSTETH() public {
        address wsteth = address(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
        IERC20(wsteth).approve(PositionManager, type(uint256).max);
        IERC20(weth).approve(PositionManager, type(uint256).max);
        INonfungiblePositionManager positionManager = INonfungiblePositionManager(PositionManager);
        IUniswapV3Pool pool = IUniswapV3Pool(IUniswapV3Factory(Factory).getPool(wsteth, weth, 500));
        deal(wsteth, address(this), 100 ether);
        deal(weth, address(this), 100 ether);
        vm.deal(address(this), 1 ether);
        (uint160 sqrtPriceX96, int24 currentTick, , , , , ) = pool.slot0();

        currentTick -= currentTick % 60;
        (uint256 tokenId, , , ) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: wsteth,
                token1: weth,
                fee: 3000,
                tickLower: currentTick - 600,
                tickUpper: currentTick + 600,
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: type(uint256).max
            })
        );

        uint256 priceD = ((sqrtPriceX96 * 10**18) / 2**96)**2 / 10**18;
        ConstPriceChainlinkOracle wstethToEthOracle = new ConstPriceChainlinkOracle(int256(priceD), 18);
        CombinedChainlinkOracle combinedOracle = new CombinedChainlinkOracle(
            IAggregatorV3(address(wstethToEthOracle)),
            IAggregatorV3(chainlinkEth)
        );

        address[] memory newOracles = chainlinkOracles;
        newOracles[0] = address(combinedOracle);
        address[] memory newTokens = tokens;
        newTokens[0] = wsteth;

        ChainlinkOracle oracle = new ChainlinkOracle(newTokens, newOracles, heartbeats, 3600);
        UniV3Oracle nftOracle = new UniV3Oracle(PositionManager, IOracle(address(oracle)), 10**16);
        (bool deviationSafety, , ) = nftOracle.price(tokenId);
        // Checking that deviation from spot price is not bigger than 1%
        assertTrue(deviationSafety);
    }
}
