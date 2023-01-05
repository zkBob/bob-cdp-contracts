// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@zkbob/proxy/EIP1967Proxy.sol";
import "../src/VaultRegistry.sol";
import "../src/Vault.sol";
import "../src/oracles/UniV3Oracle.sol";
import "./SetupContract.sol";
import "./mocks/MockOracle.sol";
import "./mocks/BobTokenMock.sol";
import "./shared/ForkTests.sol";

contract VaultRegistryTest is Test, SetupContract, AbstractMainnetForkTest {
    EIP1967Proxy vaultProxy;
    EIP1967Proxy vaultRegistryProxy;
    EIP1967Proxy univ3OracleProxy;
    UniV3Oracle univ3Oracle;
    MockOracle oracle;
    BobToken token;
    Vault vault;
    VaultRegistry vaultRegistry;
    INonfungiblePositionManager positionManager;
    address treasury;

    constructor() {
        UniV3PositionManager = address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
        UniV3Factory = address(0x1F98431c8aD98523631AE4a59f267346ea31F984);
        SwapRouter = address(0xE592427A0AEce92De3Edee1F18E0157C05861564);

        wbtc = address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
        usdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        ape = address(0x4d224452801ACEd8B2F0aebE155379bb5D594381);

        chainlinkBtc = address(0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c);
        chainlinkUsdc = address(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
        chainlinkEth = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);

        tokens = [wbtc, usdc, weth];
        chainlinkOracles = [chainlinkBtc, chainlinkUsdc, chainlinkEth];
        heartbeats = [1500, 36000, 1500];
    }

    function setUp() public {
        vm.createSelectFork(forkRpcUrl, forkBlock);
        positionManager = INonfungiblePositionManager(UniV3PositionManager);

        oracle = new MockOracle();

        setTokenPrice(oracle, wbtc, uint256(20000 << 96) * uint256(10**10));
        setTokenPrice(oracle, weth, uint256(1000 << 96));
        setTokenPrice(oracle, usdc, uint256(1 << 96) * uint256(10**12));

        univ3Oracle = new UniV3Oracle(
            INonfungiblePositionManager(UniV3PositionManager),
            IOracle(address(oracle)),
            10**16
        );

        treasury = getNextUserAddress();

        token = new BobTokenMock();

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
