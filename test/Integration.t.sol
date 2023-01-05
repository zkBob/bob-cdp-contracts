// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@zkbob/proxy/EIP1967Proxy.sol";
import "../src/Vault.sol";
import "../src/VaultRegistry.sol";
import "../src/oracles/UniV3Oracle.sol";

import "./SetupContract.sol";
import "./mocks/BobTokenMock.sol";
import "./mocks/MockOracle.sol";
import "./shared/ForkTests.sol";

abstract contract AbstractIntegrationTestForVault is Test, SetupContract, AbstractForkTest {
    IMockOracle oracle;
    BobTokenMock token;
    Vault vault;
    VaultRegistry vaultRegistry;
    UniV3Oracle univ3Oracle;
    EIP1967Proxy vaultProxy;
    EIP1967Proxy vaultRegistryProxy;
    EIP1967Proxy univ3OracleProxy;
    INonfungiblePositionManager positionManager;
    address treasury;

    uint256 YEAR = 365 * 24 * 60 * 60;

    function setUp() public {
        vm.createSelectFork(forkRpcUrl, forkBlock);
        positionManager = INonfungiblePositionManager(UniV3PositionManager);

        MockOracle oracleImpl = new MockOracle();
        oracle = IMockOracle(address(oracleImpl));

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

        vaultRegistry = new VaultRegistry(ICDP(address(vault)), "BOB Vault Token", "BVT", "");

        vaultRegistryProxy = new EIP1967Proxy(address(this), address(vaultRegistry), "");
        vaultRegistry = VaultRegistry(address(vaultRegistryProxy));

        vault.setVaultRegistry(IVaultRegistry(address(vaultRegistry)));

        token.updateMinter(address(vault), true, true);
        token.approve(address(vault), type(uint256).max);

        vault.changeLiquidationFee(3 * 10**7);
        vault.changeLiquidationPremium(3 * 10**7);
        vault.changeMinSingleNftCollateral(10**17);
        vault.changeMaxNftsPerVault(20);

        setPools(ICDP(vault));
        setApprovals();

        address[] memory depositors = new address[](1);
        depositors[0] = address(this);
        vault.addDepositorsToAllowlist(depositors);
    }

    // integration scenarios

    function testMultipleDepositAndWithdrawsSuccessSingleVault() public {
        uint256 vaultId = vault.openVault();
        uint256 nftA = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault)); // 2000 USD
        uint256 nftB = openUniV3Position(wbtc, usdc, 5 * 10**8, 100000 * 10**6, address(vault)); // 200000 USD
        (, uint256 wbtcPriceX96) = oracle.price(wbtc);
        (, uint256 wethPriceX96) = oracle.price(weth);
        makeDesiredPoolPrice(FullMath.mulDiv(wbtcPriceX96, Q96, wethPriceX96), wbtc, weth);
        uint256 nftC = openUniV3Position(wbtc, weth, 10**8 / 20000, 10**18 / 1000, address(vault)); // 2 USD

        vault.changeMinSingleNftCollateral(18 * 10**17);

        vault.depositCollateral(vaultId, nftA);
        vault.mintDebt(vaultId, 1000 * 10**18);

        vault.depositCollateral(vaultId, nftB);
        vault.mintDebt(vaultId, 50000 * 10**18);

        vault.depositCollateral(vaultId, nftC);
        vm.expectRevert(Vault.PositionUnhealthy.selector);
        vault.withdrawCollateral(nftB);

        vault.withdrawCollateral(nftC);

        positionManager.approve(address(vault), nftC);
        vault.depositCollateral(vaultId, nftC);

        vault.burnDebt(vaultId, 51000 * 10**18);
        vault.withdrawCollateral(nftB);
        vault.withdrawCollateral(nftA);

        vault.changeMinSingleNftCollateral(18 * 10**20);
        vault.mintDebt(vaultId, 10);

        vm.expectRevert(Vault.PositionUnhealthy.selector);
        vault.withdrawCollateral(nftC);

        vault.burnDebt(vaultId, 10);
        vault.withdrawCollateral(nftC);

        positionManager.approve(address(vault), nftC);
        vm.expectRevert(Vault.CollateralUnderflow.selector);
        vault.depositCollateral(vaultId, nftC);
    }

    function testFailStealNft() public {
        uint256 vaultId = vault.openVault();
        uint256 nft = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, nft);
        vault.mintDebt(vaultId, 100 * 10**18);

        positionManager.transferFrom(address(vault), address(this), nft);
    }

    function testSeveralVaultsPerAddress() public {
        uint256 vaultA = vault.openVault();
        uint256 vaultB = vault.openVault();

        uint256 nftA = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        uint256 nftB = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));

        vault.depositCollateral(vaultA, nftA);
        vault.depositCollateral(vaultB, nftB);

        vault.mintDebt(vaultA, 1000 * 10**18);
        vault.mintDebt(vaultB, 1 * 10**18);

        // bankrupt first vault

        setTokenPrice(oracle, weth, 400 << 96);
        vm.expectRevert(Vault.PositionUnhealthy.selector);
        vault.mintDebt(vaultA, 1 * 10**18);

        address liquidator = getNextUserAddress();

        deal(address(token), liquidator, 10000 * 10**18, true);
        vm.startPrank(liquidator);

        token.approve(address(vault), type(uint256).max);
        vault.liquidate(vaultA);

        // second vault is okay at the moment

        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(Vault.PositionHealthy.selector);
        vault.liquidate(vaultB);
        vm.stopPrank();

        vm.expectRevert(Vault.PositionUnhealthy.selector);
        vault.withdrawCollateral(nftB);

        vault.closeVault(vaultA, address(this));
        vm.expectRevert(Vault.UnpaidDebt.selector);
        vault.closeVault(vaultB, address(this));
    }

    function testCorrectNumerationOfVaultsPerAddress() public {
        uint256 firstVaultId = vault.openVault();
        uint256 secondVaultId = vault.openVault();
        assertEq(vaultRegistry.tokenOfOwnerByIndex(address(this), 0), firstVaultId);
        assertEq(vaultRegistry.tokenOfOwnerByIndex(address(this), 1), secondVaultId);

        vm.expectRevert("ERC721Enumerable: owner index out of bounds");
        vaultRegistry.tokenOfOwnerByIndex(address(this), 2);

        vaultRegistry.transferFrom(address(this), getNextUserAddress(), firstVaultId);
        assertEq(vaultRegistry.tokenOfOwnerByIndex(address(this), 0), secondVaultId);
    }

    function testOneUserClosesDebtOfSecond() public {
        address firstAddress = address(this);

        address secondAddress = getNextUserAddress();
        address[] memory depositors = new address[](1);
        depositors[0] = secondAddress;
        vault.addDepositorsToAllowlist(depositors);

        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        uint256 secondNft = openUniV3Position(weth, usdc, 10**18, 10**9, secondAddress);

        positionManager.transferFrom(address(this), secondAddress, secondNft);
        vault.depositCollateral(vaultId, tokenId);

        vault.mintDebt(vaultId, 1180 * 10**18);
        vm.startPrank(secondAddress);

        positionManager.approve(address(vault), secondNft);
        uint256 secondVault = vault.openVault();
        vault.depositCollateral(secondVault, secondNft);
        vault.mintDebt(secondVault, 230 * 10**18);

        vm.stopPrank();
        vm.warp(block.timestamp + 4 * YEAR);
        (, uint256 healthFactor) = vault.calculateVaultCollateral(vaultId);
        assertTrue(vault.getOverallDebt(vaultId) > healthFactor);

        vm.startPrank(secondAddress);
        token.transfer(firstAddress, 230 * 10**18);
        vm.stopPrank();

        vault.burnDebt(vaultId, token.balanceOf(firstAddress));
        vault.closeVault(vaultId, address(this));
    }

    function testPriceDroppedAndGotBackNotLiquidated() public {
        uint256 vaultId = vault.openVault();
        // overall ~2000$ -> HF: ~1200$
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1000 * 10**18);
        // eth 1000 -> 800
        setTokenPrice(oracle, weth, 800 << 96);

        (, uint256 healthFactor) = vault.calculateVaultCollateral(vaultId);
        uint256 overallDebt = vault.vaultDebt(vaultId) + vault.stabilisationFeeVaultSnapshot(vaultId);
        assertTrue(healthFactor <= overallDebt); // hence subject to liquidation

        setTokenPrice(oracle, weth, 1200 << 96); // price got back

        address liquidator = getNextUserAddress();
        deal(address(token), liquidator, 10000 * 10**18, true);
        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(Vault.PositionHealthy.selector);
        vault.liquidate(vaultId); // hence not liquidated
        vm.stopPrank();
    }

    function testLiquidatedAfterDebtFeesCame() public {
        uint256 vaultId = vault.openVault();
        // overall ~2000$ -> HF: ~1200$
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1000 * 10**18);

        vault.updateStabilisationFeeRate(5 * 10**7);

        vm.warp(block.timestamp + 5 * YEAR);
        address liquidator = getNextUserAddress();
        deal(address(token), liquidator, 10000 * 10**18, true);
        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);
        vault.liquidate(vaultId); // liquidated
        assertTrue(token.balanceOf(treasury) > 0); // liquidation succeded
        vm.stopPrank();
    }

    function testSeveralLiquidationsGetOkay() public {
        uint256 oldTreasuryBalance = 0;

        for (uint8 i = 0; i < 5; ++i) {
            uint256 vaultId = vault.openVault();
            uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
            vault.depositCollateral(vaultId, tokenId);
            vault.mintDebt(vaultId, 1000 * 10**18);
            setTokenPrice(oracle, weth, 800 << 96);

            address liquidator = getNextUserAddress();
            deal(address(token), liquidator, 10000 * 10**18, true);

            vm.startPrank(liquidator);
            token.approve(address(vault), type(uint256).max);
            vault.liquidate(vaultId); // liquidated

            uint256 newTreasuryBalance = token.balanceOf(treasury);
            assertTrue(oldTreasuryBalance < newTreasuryBalance);
            oldTreasuryBalance = newTreasuryBalance;
            vm.stopPrank();

            setTokenPrice(oracle, weth, 1000 << 96);
        }
    }

    function testMintBurnStabilizationFee() public {
        vm.warp(block.timestamp + YEAR);

        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**20, 10**11, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        vault.mintDebt(vaultId, 1000 * 10**18);
        assertEq(vault.getOverallDebt(vaultId), 1000 * 10**18);

        vm.warp(block.timestamp + YEAR);
        assertEq(vault.getOverallDebt(vaultId), 1010 * 10**18);

        vault.mintDebt(vaultId, 2000 * 10**18);
        assertEq(vault.getOverallDebt(vaultId), 3010 * 10**18);

        vm.warp(block.timestamp + YEAR);
        assertEq(vault.getOverallDebt(vaultId), 3040 * 10**18);

        vault.burnDebt(vaultId, 1500 * 10**18);
        assertEq(vault.getOverallDebt(vaultId), 1540 * 10**18);

        vm.warp(block.timestamp + YEAR);
        assertEq(vault.getOverallDebt(vaultId), 1555 * 10**18);

        vault.updateStabilisationFeeRate(5 * 10**7); // 5%
        vm.warp(block.timestamp + YEAR);
        assertEq(vault.getOverallDebt(vaultId), 1630 * 10**18);

        vault.updateStabilisationFeeRate(1 * 10**7); // 1%
        vm.warp(block.timestamp + YEAR);
        assertEq(vault.getOverallDebt(vaultId), 1645 * 10**18);
        vault.updateStabilisationFeeRate(5 * 10**7); // 5%
        vm.warp(block.timestamp + YEAR);
        assertEq(vault.getOverallDebt(vaultId), 1720 * 10**18);

        vault.burnDebt(vaultId, 900 * 10**18);
        assertEq(vault.getOverallDebt(vaultId), 820 * 10**18);

        vault.updateStabilisationFeeRate(0); // 0%
        vm.warp(block.timestamp + 10 * YEAR);
        assertEq(vault.getOverallDebt(vaultId), 820 * 10**18);

        deal(address(token), address(this), 820 * 10**18, true);
        vault.burnDebt(vaultId, 820 * 10**18);
        vault.closeVault(vaultId, address(this));
    }

    function testFeesUpdatedAfterSecond() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**20, 10**11, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        vault.mintDebt(vaultId, 1000 * 10**18);
        uint256 beforeDebt = vault.getOverallDebt(vaultId);

        vault.updateStabilisationFeeRate(10**8);
        vm.warp(block.timestamp + 1);

        uint256 afterDebt = vault.getOverallDebt(vaultId);
        assertTrue(beforeDebt != afterDebt);
    }

    function testFeesCalculatedProportionally() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**20, 10**11, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        vault.mintDebt(vaultId, 1000 * 10**18);
        uint256 beforeDebt = vault.getOverallDebt(vaultId);

        vm.warp(block.timestamp + 3600);
        uint256 hourFee = vault.getOverallDebt(vaultId) - beforeDebt;
        vm.warp(block.timestamp + 3600 * 23);

        uint256 dailyFee = vault.getOverallDebt(vaultId) - beforeDebt;
        assertApproxEqual(dailyFee / 24, hourFee, 1); // <0.1% delta
    }

    function testFeesUpdatedAfterAllOnlyMintBurn() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenA = openUniV3Position(weth, usdc, 10**20, 10**11, address(vault));
        uint256 tokenB = openUniV3Position(weth, usdc, 10**20, 10**11, address(vault));
        vault.depositCollateral(vaultId, tokenA);
        vault.mintDebt(vaultId, 1000 * 10**18);

        uint256 currentDebt = vault.stabilisationFeeVaultSnapshot(vaultId);

        vm.warp(block.timestamp + YEAR);
        vault.mintDebt(vaultId, 0);
        uint256 newDebt = vault.stabilisationFeeVaultSnapshot(vaultId);
        assertTrue(currentDebt < newDebt);
        currentDebt = newDebt;

        vm.warp(block.timestamp + YEAR);
        vault.burnDebt(vaultId, 0);
        newDebt = vault.stabilisationFeeVaultSnapshot(vaultId);
        assertTrue(currentDebt < newDebt);
        currentDebt = newDebt;

        vm.warp(block.timestamp + YEAR);
        vault.depositCollateral(vaultId, tokenB);
        newDebt = vault.stabilisationFeeVaultSnapshot(vaultId);
        assertTrue(currentDebt == newDebt);
        currentDebt = newDebt;

        vm.warp(block.timestamp + YEAR);
        vault.withdrawCollateral(tokenB);
        newDebt = vault.stabilisationFeeVaultSnapshot(vaultId);
        assertTrue(currentDebt == newDebt);
    }

    function testReasonablePoolFeesCalculating() public {
        uint256 vaultId = vault.openVault();
        uint256 nftA = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, nftA);

        (, uint256 healthBeforeSwaps) = vault.calculateVaultCollateral(vaultId);
        vault.mintDebt(vaultId, healthBeforeSwaps - 1);

        vm.expectRevert(Vault.PositionUnhealthy.selector);
        vault.mintDebt(vaultId, 100);

        setTokenPrice(oracle, weth, 999 << 96); // small price change to make position slightly lower than health threshold
        (, uint256 healthAfterPriceChanged) = vault.calculateVaultCollateral(vaultId);
        uint256 debt = vault.vaultDebt(vaultId);

        assertTrue(healthAfterPriceChanged <= debt);

        uint256 amountOut = makeSwap(weth, usdc, 10**22); // have to get a lot of fees
        makeSwap(usdc, weth, amountOut);

        (, uint256 healthAfterSwaps) = vault.calculateVaultCollateral(vaultId);

        assertTrue(healthBeforeSwaps * 100001 <= healthAfterSwaps * 100000);
        assertApproxEqual(healthAfterSwaps, healthBeforeSwaps, 3); // difference < 0.3% though

        address liquidator = getNextUserAddress();
        deal(address(token), liquidator, 10000 * 10**18, true);
        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(Vault.PositionHealthy.selector);
        vault.liquidate(vaultId); // hence not liquidated
        vm.stopPrank();
    }

    function LiquidationThresholdChangedHenceLiquidated() public {
        uint256 vaultId = vault.openVault();

        uint256 nftA = openUniV3Position(weth, usdc, 10**19, 10**10, address(vault)); // 20000 USD
        vault.depositCollateral(vaultId, nftA);
        vault.mintDebt(vaultId, 10000 * (10**18));

        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);

        vault.setLiquidationThreshold(pool, 2 * 10**8);
        vault.burnDebt(vaultId, 5000 * (10**18)); // repaid debt partially and anyway liquidated

        address liquidator = getNextUserAddress();
        deal(address(token), liquidator, 100000 * 10**18, true);
        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);
        vault.liquidate(vaultId);
        vm.stopPrank();
    }
}

contract MainnetUniswapIntegrationTestForVault is AbstractIntegrationTestForVault, AbstractMainnetForkTest {
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
}

contract PolygonUniswapIntegrationTestForVault is AbstractIntegrationTestForVault, AbstractPolygonForkTest {
    constructor() {
        UniV3PositionManager = address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
        UniV3Factory = address(0x1F98431c8aD98523631AE4a59f267346ea31F984);
        SwapRouter = address(0xE592427A0AEce92De3Edee1F18E0157C05861564);

        wbtc = address(0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6);
        usdc = address(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);
        weth = address(0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619);
        ape = address(0xB7b31a6BC18e48888545CE79e83E06003bE70930);

        chainlinkBtc = address(0xc907E116054Ad103354f2D350FD2514433D57F6f);
        chainlinkUsdc = address(0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7);
        chainlinkEth = address(0xF9680D99D6C9589e2a93a78A04A279e509205945);

        tokens = [wbtc, usdc, weth];
        chainlinkOracles = [chainlinkBtc, chainlinkUsdc, chainlinkEth];
        heartbeats = [120, 120, 120];
    }
}
