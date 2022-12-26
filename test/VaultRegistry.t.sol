// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "./SetupContract.sol";
import "./utils/Utilities.sol";
import "../src/VaultRegistry.sol";
import "../src/proxy/EIP1967Proxy.sol";
import "./mocks/MockOracle.sol";
import "./mocks/MUSD.sol";
import "../src/Vault.sol";
import "../src/oracles/UniV3Oracle.sol";

contract VaultRegistryTest is Test, SetupContract, Utilities {
    EIP1967Proxy vaultProxy;
    EIP1967Proxy vaultRegistryProxy;
    EIP1967Proxy univ3OracleProxy;
    UniV3Oracle univ3Oracle;
    MockOracle oracle;
    MUSD token;
    Vault vault;
    VaultRegistry vaultRegistry;
    INonfungiblePositionManager positionManager;
    address treasury;

    function setUp() public {
        positionManager = INonfungiblePositionManager(UniV3PositionManager);

        oracle = new MockOracle();

        oracle.setPrice(wbtc, uint256(20000 << 96) * uint256(10**10));
        oracle.setPrice(weth, uint256(1000 << 96));
        oracle.setPrice(usdc, uint256(1 << 96) * uint256(10**12));

        univ3Oracle = new UniV3Oracle(
            INonfungiblePositionManager(UniV3PositionManager),
            IUniswapV3Factory(UniV3Factory),
            IOracle(address(oracle))
        );
        univ3OracleProxy = new EIP1967Proxy(address(this), address(univ3Oracle), "");
        univ3Oracle = UniV3Oracle(address(univ3OracleProxy));

        treasury = getNextUserAddress();

        token = new MUSD("Mock USD", "MUSD");

        vault = new Vault(
            INonfungiblePositionManager(UniV3PositionManager),
            INFTOracle(address(univ3Oracle)),
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

        setPools(ICDP(vault));
        setApprovals();

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
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
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
