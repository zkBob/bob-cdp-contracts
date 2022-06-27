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

contract MUSDTest is Test, SetupContract, Utilities {
    MUSD token;

    function setUp() public {
        token = new MUSD("Mellow USD", "MUSD", address(this));
    }

    // mint

    function testMintSuccess() public {
        address randomAddress = getNextUserAddress();
        token.mint(randomAddress, 10);
        assertEq(token.balanceOf(randomAddress), 10);
    }

    function testMintWhenNoPermission() public {
        vm.prank(getNextUserAddress());
        vm.expectRevert(MUSD.Forbidden.selector);
        token.mint(getNextUserAddress(), 10);
    }

    // burn

    function testBurnSuccess() public {
        address randomAddress = getNextUserAddress();
        token.mint(randomAddress, 10);
        token.burn(randomAddress, 5);
        assertEq(token.balanceOf(randomAddress), 5);
    }

    function testFailBurnWithZeroAmount() public {
        address randomAddress = getNextUserAddress();
        token.burn(randomAddress, 10);
    }

    function testBurnWhenNoPermission() public {
        vm.prank(getNextUserAddress());
        vm.expectRevert(MUSD.Forbidden.selector);
        token.burn(getNextUserAddress(), 10);
    }
}