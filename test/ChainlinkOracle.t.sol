// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
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

contract ChainlinkOracleTest is Test, SetupContract, Utilities {
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

    function testSupportedTokens() public {
        address[] memory supportedTokens = oracle.supportedTokens();
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(supportedTokens[i], tokens[i]);
        }
    }

    // addChainlinkOracles

    function testAddChainlinkOracles() public {
        address[] memory emptyTokens = new address[](0);
        address[] memory emptyOracles = new address[](0);
        ChainlinkOracle currentOracle = new ChainlinkOracle(emptyTokens, emptyOracles, address(this));

        currentOracle.addChainlinkOracles(tokens, chainlinkOracles);

        for (uint256 i = 0; i < 3; ++i) {
            assertTrue(currentOracle.hasOracle(tokens[i]));
        }
    }
}