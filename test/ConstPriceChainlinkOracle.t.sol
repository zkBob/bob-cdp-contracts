import "./SetupContract.sol";
import "./shared/AbstractConfigContract.sol";
import "./shared/ForkTests.sol";
import "../src/oracles/ConstPriceChainlinkOracle.sol";

contract ConstPriceChainlinkOracleTest is
    Test,
    SetupContract,
    AbstractMainnetForkTest,
    AbstractMainnetUniswapConfigContract
{
    function setUp() public {
        vm.createSelectFork(forkRpcUrl, forkBlock);
    }

    function testConstPriceChainlinkOracle() public {
        ConstPriceChainlinkOracle chainlinkOracle = new ConstPriceChainlinkOracle(1 ether, 8);
        assertEq(chainlinkOracle.decimals(), 8);
        for (uint256 i = 0; i < 2; ++i) {
            (, int256 answer, , uint256 updatedAt, ) = chainlinkOracle.latestRoundData();
            assertEq(answer, 1 ether);
            assertEq(updatedAt, block.timestamp);
            vm.warp(block.timestamp + 100);
        }
    }
}
