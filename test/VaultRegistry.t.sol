// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "./SetupContract.sol";
import "./utils/Utilities.sol";
import "../src/VaultRegistry.sol";
import "../src/proxy/EIP1967Proxy.sol";

contract VaultRegistryTest is Test, SetupContract, Utilities {
    VaultRegistry vaultRegistry;
    EIP1967Proxy vaultRegistryProxy;

    function setUp() public {
        vaultRegistry = new VaultRegistry(address(this), "BOB Vault Token", "BVT", "baseURI/");

        vaultRegistryProxy = new EIP1967Proxy(address(this), address(vaultRegistry), "");
        vaultRegistry = VaultRegistry(address(vaultRegistryProxy));
    }

    // mint

    function testMintSuccess() public {
        address userAddress = getNextUserAddress();
        vaultRegistry.mint(userAddress, 1);
        assertEq(vaultRegistry.ownerOf(1), userAddress);
    }

    function testMintWhenNotMinter() public {
        vm.prank(getNextUserAddress());
        vm.expectRevert(VaultRegistry.Forbidden.selector);
        vaultRegistry.mint(getNextUserAddress(), 1);
    }

    // name

    function testName() public {
        assertEq(vaultRegistry.name(), "BOB Vault Token");
    }

    // symbol

    function testSymbol() public {
        assertEq(vaultRegistry.symbol(), "BVT");
    }

    // baseURI

    function testBaseURI() public {
        vaultRegistry.mint(getNextUserAddress(), 1);
        assertEq(vaultRegistry.tokenURI(1), "baseURI/1");
    }
}
