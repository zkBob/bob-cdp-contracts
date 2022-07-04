// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "forge-std/console2.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../lib/forge-std/src/Test.sol";
import "./ConfigContract.sol";
import "./SetupContract.sol";
import "../src/Vault.sol";
import "../src/MUSD.sol";
import "./mocks/MockOracle.sol";
import "../src/interfaces/external/univ3/IUniswapV3Factory.sol";
import "../src/interfaces/external/univ3/IUniswapV3Pool.sol";
import "../src/interfaces/external/univ3/INonfungiblePositionManager.sol";
import "./utils/Utilities.sol";
import "./mocks/MockChainlinkOracle.sol";

contract ChainlinkOracleTest is Test, SetupContract, Utilities {
    event TokensAndOraclesAdded(address indexed origin, address indexed sender, address[] tokens, address[] oracles);

    ChainlinkOracle oracle;

    function setUp() public {
        oracle = deployChainlink();
    }

    // hasOracle

    function testHasOracleExistedToken() public {
        for (uint256 i = 0; i < 3; ++i) {
            assertTrue(oracle.hasOracle(tokens[i]));
        }
    }

    function testHasOracleNonExistedToken() public {
        assertFalse(oracle.hasOracle(getNextUserAddress()));
    }

    // supportedTokens

    function testSupportedTokensSuccess() public {
        address[] memory supportedTokens = oracle.supportedTokens();
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(supportedTokens[i], tokens[i]);
        }
    }

    // addChainlinkOracles

    function testAddChainlinkOraclesSuccess() public {
        address[] memory emptyTokens = new address[](0);
        address[] memory emptyOracles = new address[](0);
        ChainlinkOracle currentOracle = new ChainlinkOracle(emptyTokens, emptyOracles, address(this));

        currentOracle.addChainlinkOracles(tokens, chainlinkOracles);

        for (uint256 i = 0; i < 3; ++i) {
            assertTrue(currentOracle.hasOracle(tokens[i]));
        }
    }

    function testAddChainlinkOraclesEmit() public {
        address[] memory emptyTokens = new address[](0);
        address[] memory emptyOracles = new address[](0);
        ChainlinkOracle currentOracle = new ChainlinkOracle(emptyTokens, emptyOracles, address(this));

        vm.expectEmit(false, true, false, true);
        emit TokensAndOraclesAdded(getNextUserAddress(), address(this), tokens, chainlinkOracles);
        currentOracle.addChainlinkOracles(tokens, chainlinkOracles);
    }

    function testAddChainlinkOraclesWhenInvalidValue() public {
        address[] memory currentTokens = new address[](1);
        currentTokens[0] = wbtc;
        address[] memory currentOracles = new address[](0);

        vm.expectRevert(ChainlinkOracle.InvalidValue.selector);
        oracle.addChainlinkOracles(currentTokens, currentOracles);
    }

    // price

    function testPrice() public {
        assertApproxEqual(1500, oracle.price(weth) >> 96, 500);
        assertApproxEqual(10**12, oracle.price(usdc) >> 96, 50);
        assertApproxEqual(20000 * (10**10), oracle.price(wbtc) >> 96, 500);
    }

    function testPriceReturnsZeroForNonSetToken() public {
        assertEq(oracle.price(getNextUserAddress()), 0);
    }

    function testPriceReturnsZeroForBrokenOracle() public {
        MockChainlinkOracle mockOracle = new MockChainlinkOracle();

        address[] memory currentTokens = new address[](1);
        currentTokens[0] = ape;
        address[] memory currentOracles = new address[](1);
        currentOracles[0] = address(mockOracle);

        oracle.addChainlinkOracles(currentTokens, currentOracles);

        assertEq(oracle.price(ape), 0);
    }
}
