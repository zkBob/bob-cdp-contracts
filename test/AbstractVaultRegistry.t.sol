// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@zkbob/proxy/EIP1967Proxy.sol";
import "../src/VaultRegistry.sol";
import "../src/Vault.sol";
import "./SetupContract.sol";
import "./mocks/MockOracle.sol";
import "./mocks/BobTokenMock.sol";
import "./shared/ForkTests.sol";

abstract contract AbstractVaultRegistryTest is Test, SetupContract, AbstractForkTest, AbstractLateSetup {
    EIP1967Proxy vaultProxy;
    EIP1967Proxy vaultRegistryProxy;
    BobToken token;
    Vault vault;
    VaultRegistry vaultRegistry;
    INonfungiblePositionManager positionManager;
    address treasury;

    function setUp() public {
        vm.createSelectFork(forkRpcUrl, forkBlock);
        _setUp();
        positionManager = INonfungiblePositionManager(PositionManager);

        helper.setTokenPrice(oracle, wbtc, uint256(20000 << 96) * uint256(10**10));
        helper.setTokenPrice(oracle, weth, uint256(1000 << 96));
        helper.setTokenPrice(oracle, usdc, uint256(1 << 96) * uint256(10**12));

        treasury = getNextUserAddress();

        token = new BobTokenMock();

        vault = new Vault(
            INonfungiblePositionManager(PositionManager),
            INFTOracle(address(nftOracle)),
            treasury,
            address(token)
        );

        bytes memory initData = abi.encodeWithSelector(
            Vault.initialize.selector,
            address(this),
            10**7,
            type(uint256).max
        );
        vaultProxy = new EIP1967Proxy(address(this), address(vault), initData);
        vault = Vault(address(vaultProxy));

        vaultRegistry = new VaultRegistry(ICDP(address(vault)), "BOB Vault Token", "BVT", "baseURI/");

        vaultRegistryProxy = new EIP1967Proxy(address(this), address(vaultRegistry), "");
        vaultRegistry = VaultRegistry(address(vaultRegistryProxy));

        vault.setVaultRegistry(IVaultRegistry(address(vaultRegistry)));

        token.approve(address(vault), type(uint256).max);

        vault.changeLiquidationFee(3 * 10**7);
        vault.changeLiquidationPremium(3 * 10**7);
        vault.changeMinSingleNftCollateral(10**17);
        vault.changeMaxNftsPerVault(12);
        vault.grantRole(vault.ADMIN_ROLE(), address(helper));

        helper.setPools(ICDP(vault));
        helper.setApprovals();

        address[] memory depositors = new address[](1);
        depositors[0] = address(this);
        vault.addDepositorsToAllowlist(depositors);
    }

    // mint

    function testMintSuccess() public {
        vm.prank(address(vault));
        address userAddress = getNextUserAddress();
        vaultRegistry.mint(userAddress, 1);
        assertEq(vaultRegistry.ownerOf(1), userAddress);
    }

    function testMintWhenNotMinter() public {
        vm.prank(getNextUserAddress());
        vm.expectRevert(VaultRegistry.Forbidden.selector);
        vaultRegistry.mint(getNextUserAddress(), 1);
    }

    // burn

    function testBurnSuccess() public {
        uint256 vaultId = vault.openVault();
        assertEq(vaultRegistry.balanceOf(address(this)), 1);
        vaultRegistry.burn(vaultId);
        assertEq(vaultRegistry.balanceOf(address(this)), 0);
    }

    function testBurnWhenNotOwner() public {
        uint256 vaultId = vault.openVault();
        vm.expectRevert(VaultRegistry.Forbidden.selector);
        vm.prank(getNextUserAddress());
        vaultRegistry.burn(vaultId);
    }

    function testBurnWhenNonEmptyCollateral() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vm.expectRevert(VaultRegistry.NonEmptyCollateral.selector);
        vaultRegistry.burn(vaultId);
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
        vm.prank(address(vault));
        vaultRegistry.mint(getNextUserAddress(), 1);
        assertEq(vaultRegistry.tokenURI(1), "baseURI/1");
    }
}
