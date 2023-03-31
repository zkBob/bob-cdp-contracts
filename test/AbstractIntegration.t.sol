// SPDX-License-Identifier: CC0-1.0

pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@zkbob/proxy/EIP1967Proxy.sol";
import "@zkbob/minters/DebtMinter.sol" as DebtMinter;
import "@zkbob/minters/SurplusMinter.sol" as TreasuryMinter;
import "../src/Vault.sol";
import "../src/VaultRegistry.sol";

import "./SetupContract.sol";
import "./mocks/BobTokenMock.sol";
import "./mocks/MockOracle.sol";
import "./mocks/VaultMock.sol";
import "./shared/ForkTests.sol";

abstract contract AbstractIntegrationTestForVault is SetupContract, AbstractForkTest, AbstractLateSetup {
    BobTokenMock token;
    VaultMock vault;
    VaultRegistry vaultRegistry;
    EIP1967Proxy vaultProxy;
    EIP1967Proxy vaultRegistryProxy;
    EIP1967Proxy nftOracleProxy;
    INonfungiblePositionManager positionManager;
    ITreasury treasury;

    uint256 YEAR = 365 * 24 * 60 * 60;

    function setUp() public {
        vm.createSelectFork(forkRpcUrl, forkBlock);
        _setUp();

        positionManager = INonfungiblePositionManager(PositionManager);

        helper.setTokenPrice(oracle, wbtc, uint256(20000 << 96) * uint256(10**10));
        helper.setTokenPrice(oracle, weth, uint256(1000 << 96));
        helper.setTokenPrice(oracle, usdc, uint256(1 << 96) * uint256(10**12));

        token = new BobTokenMock();

        TreasuryMinter.SurplusMinter treasuryImpl = new TreasuryMinter.SurplusMinter(address(token));
        treasury = ITreasury(address(treasuryImpl));

        vaultRegistry = new VaultRegistry("BOB Vault Token", "BVT", "");
        vaultRegistryProxy = new EIP1967Proxy(address(this), address(vaultRegistry), "");
        vaultRegistry = VaultRegistry(address(vaultRegistryProxy));

        DebtMinter.DebtMinter debtMinterImpl = new DebtMinter.DebtMinter(
            address(token),
            type(uint104).max,
            type(uint104).max - 1000,
            0,
            1,
            address(treasury)
        );

        vault = new VaultMock(
            INonfungiblePositionManager(PositionManager),
            INFTOracle(address(nftOracle)),
            address(treasury),
            address(token),
            address(debtMinterImpl),
            address(vaultRegistry)
        );

        bytes memory initData = abi.encodeWithSelector(
            Vault.initialize.selector,
            address(this),
            10**16 / YEAR,
            type(uint256).max
        );
        vaultProxy = new EIP1967Proxy(address(this), address(vault), initData);
        vault = VaultMock(address(vaultProxy));

        debtMinterImpl.setMinter(address(vault), true);
        treasuryImpl.setMinter(address(vault), true);
        vaultRegistry.setMinter(address(vault), true);

        token.updateMinter(address(debtMinterImpl), true, true);
        token.updateMinter(address(treasuryImpl), true, true);
        token.approve(address(vault), type(uint256).max);

        vault.changeLiquidationFee(3 * 10**7);
        vault.changeLiquidationPremium(3 * 10**7);
        vault.changeMinSingleNftCollateral(10**17);
        vault.changeMaxNftsPerVault(12);
        vault.grantRole(vault.ADMIN_ROLE(), address(helper));

        helper.setPools(vault);
        helper.setApprovals();

        address[] memory depositors = new address[](1);
        depositors[0] = address(this);
        vault.addDepositorsToAllowlist(depositors);

        vault.makeLiquidationsPublic();

        skip(1 days);
    }

    // integration scenarios

    function testMultipleDepositAndWithdrawsSuccessSingleVault() public {
        uint256 vaultId = vault.openVault();
        uint256 nftA = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault)); // 2000 USD
        uint256 nftB = helper.openPosition(wbtc, usdc, 5 * 10**8, 100000 * 10**6, address(vault)); // 200000 USD
        (, uint256 wbtcPriceX96) = oracle.price(wbtc);
        vault.checkInvariantOnVault(vaultId);
        (, uint256 wethPriceX96) = oracle.price(weth);
        helper.makeDesiredPoolPrice(FullMath.mulDiv(wbtcPriceX96, Q96, wethPriceX96), wbtc, weth);
        uint256 nftC = helper.openPosition(wbtc, weth, 10**8 / 20000, 10**18 / 1000, address(vault)); // 2 USD

        vault.changeMinSingleNftCollateral(18 * 10**17);

        vault.depositCollateral(vaultId, nftA);
        vault.mintDebt(vaultId, 1000 ether);
        vault.checkInvariantOnVault(vaultId);

        vault.depositCollateral(vaultId, nftB);
        vault.mintDebt(vaultId, 50000 ether);
        vault.checkInvariantOnVault(vaultId);

        vault.depositCollateral(vaultId, nftC);
        vm.expectRevert(Vault.PositionUnhealthy.selector);
        vault.withdrawCollateral(nftB);

        vault.withdrawCollateral(nftC);

        positionManager.approve(address(vault), nftC);
        vault.depositCollateral(vaultId, nftC);

        vault.burnDebt(vaultId, 51000 ether);
        vault.checkInvariantOnVault(vaultId);
        vault.withdrawCollateral(nftB);
        vault.withdrawCollateral(nftA);

        vault.changeMinSingleNftCollateral(18 * 10**20);
        vault.mintDebt(vaultId, 10);
        vault.checkInvariantOnVault(vaultId);

        vm.expectRevert(Vault.PositionUnhealthy.selector);
        vault.withdrawCollateral(nftC);

        vault.burnDebt(vaultId, 10);
        vault.checkInvariantOnVault(vaultId);
        vault.withdrawCollateral(nftC);

        positionManager.approve(address(vault), nftC);
        vm.expectRevert(Vault.CollateralUnderflow.selector);
        vault.depositCollateral(vaultId, nftC);
    }

    function testFailStealNft() public {
        uint256 vaultId = vault.openVault();
        uint256 nft = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, nft);
        vault.mintDebt(vaultId, 100 ether);

        positionManager.transferFrom(address(vault), address(this), nft);
    }

    function testSeveralVaultsPerAddress() public {
        uint256 vaultA = vault.openVault();
        uint256 vaultB = vault.openVault();

        uint256 nftA = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        uint256 nftB = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));

        vault.depositCollateral(vaultA, nftA);
        vault.depositCollateral(vaultB, nftB);

        uint256[] memory vaultIds = new uint256[](2);
        vaultIds[0] = vaultA;
        vaultIds[1] = vaultB;

        vault.mintDebt(vaultA, 1000 ether);
        vault.checkInvariantOnVaults(vaultIds);
        vault.mintDebt(vaultB, 1 ether);
        vault.checkInvariantOnVaults(vaultIds);

        // bankrupt first vault

        helper.setTokenPrice(oracle, weth, 400 << 96);
        vm.expectRevert(Vault.PositionUnhealthy.selector);
        vault.mintDebt(vaultA, 1 ether);

        address liquidator = getNextUserAddress();

        deal(address(token), liquidator, 10000 ether, true);
        vm.startPrank(liquidator);

        token.approve(address(vault), type(uint256).max);
        vault.liquidate(vaultA);
        vault.checkInvariantOnVaults(vaultIds);

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
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        uint256 secondNft = helper.openPosition(weth, usdc, 10**18, 10**9, secondAddress);

        positionManager.transferFrom(address(this), secondAddress, secondNft);
        vault.depositCollateral(vaultId, tokenId);

        vault.mintDebt(vaultId, 1180 ether);
        vault.checkInvariantOnVault(vaultId);
        vm.startPrank(secondAddress);

        positionManager.approve(address(vault), secondNft);
        uint256 secondVault = vault.openVault();
        vault.depositCollateral(secondVault, secondNft);
        vault.mintDebt(secondVault, 230 ether);

        uint256[] memory vaultIds = new uint256[](2);
        vaultIds[0] = vaultId;
        vaultIds[1] = secondVault;
        vault.checkInvariantOnVaults(vaultIds);

        vm.stopPrank();
        vm.warp(block.timestamp + 20 * YEAR);
        (, uint256 liquidationLimit, ) = vault.calculateVaultCollateral(vaultId);
        assertGt(vault.getOverallDebt(vaultId), liquidationLimit);

        deal(address(token), firstAddress, 2000 ether);

        vault.burnDebt(vaultId, vault.getOverallDebt(vaultId));
        vault.checkInvariantOnVaults(vaultIds);
        vault.closeVault(vaultId, address(this));
    }

    function testPriceDroppedAndGotBackNotLiquidated() public {
        uint256 vaultId = vault.openVault();
        // overall ~2000$ -> HF: ~1200$
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1180 ether);
        vault.checkInvariantOnVault(vaultId);
        // eth 1000 -> 800
        helper.setTokenPrice(oracle, weth, 800 << 96);

        (, uint256 liquidationLimit, ) = vault.calculateVaultCollateral(vaultId);
        uint256 overallDebt = vault.getOverallDebt(vaultId);
        assertLe(liquidationLimit, overallDebt); // hence subject to liquidation

        helper.setTokenPrice(oracle, weth, 1200 << 96); // price got back

        address liquidator = getNextUserAddress();
        deal(address(token), liquidator, 10000 ether, true);
        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(Vault.PositionHealthy.selector);
        vault.liquidate(vaultId); // hence not liquidated
        vm.stopPrank();
    }

    function testLiquidatedAfterDebtFeesCame() public {
        uint256 vaultId = vault.openVault();
        // overall ~2000$ -> HF: ~1200$
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1000 ether);
        vault.checkInvariantOnVault(vaultId);

        vault.updateStabilisationFeeRate((5 * 10**16) / YEAR);

        vm.warp(block.timestamp + 10 * YEAR);
        address liquidator = getNextUserAddress();
        deal(address(token), liquidator, 10000 ether, true);
        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);
        vault.checkInvariantOnVault(vaultId);
        vault.liquidate(vaultId); // liquidated
        vault.checkInvariantOnVault(vaultId);
        assertTrue(token.balanceOf(address(treasury)) > 0); // liquidation succeded
        vm.stopPrank();
    }

    function testSeveralLiquidationsGetOkay() public {
        uint256 oldTreasuryBalance = 0;

        for (uint8 i = 0; i < 5; ++i) {
            uint256 vaultId = vault.openVault();
            uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
            vault.depositCollateral(vaultId, tokenId);
            vault.mintDebt(vaultId, 1180 ether);
            vault.checkInvariantOnVault(vaultId);
            helper.setTokenPrice(oracle, weth, 800 << 96);

            address liquidator = getNextUserAddress();
            deal(address(token), liquidator, 10000 ether, true);

            vm.startPrank(liquidator);
            vault.checkInvariantOnVault(vaultId);
            token.approve(address(vault), type(uint256).max);
            vault.liquidate(vaultId); // liquidated
            vault.checkInvariantOnVault(vaultId);

            uint256 newTreasuryBalance = token.balanceOf(address(treasury));
            assertTrue(oldTreasuryBalance < newTreasuryBalance);
            oldTreasuryBalance = newTreasuryBalance;
            vm.stopPrank();

            helper.setTokenPrice(oracle, weth, 1000 << 96);
        }
    }

    function testMintBurnStabilizationFee() public {
        vm.warp(block.timestamp + YEAR);

        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**20, 10**11, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        vault.mintDebt(vaultId, 1000 ether);
        vault.checkInvariantOnVault(vaultId);
        assertApproxEqual(vault.getOverallDebt(vaultId), 1000 ether, 1);

        vm.warp(block.timestamp + YEAR);
        assertApproxEqual(vault.getOverallDebt(vaultId), 1010 ether, 1);

        vault.checkInvariantOnVault(vaultId);
        vault.mintDebt(vaultId, 2000 ether);
        assertApproxEqual(vault.getOverallDebt(vaultId), 3010 ether, 1);

        vm.warp(block.timestamp + YEAR);
        assertApproxEqual(vault.getOverallDebt(vaultId), 3040 ether, 1);

        vault.checkInvariantOnVault(vaultId);
        vault.burnDebt(vaultId, 1500 ether);
        assertApproxEqual(vault.getOverallDebt(vaultId), 1540 ether, 1);

        vm.warp(block.timestamp + YEAR);
        assertApproxEqual(vault.getOverallDebt(vaultId), 1555 ether, 1);

        vault.updateStabilisationFeeRate((5 * 10**16) / YEAR); // 5%
        vm.warp(block.timestamp + YEAR);
        vault.checkInvariantOnVault(vaultId);
        assertApproxEqual(vault.getOverallDebt(vaultId), 1632.75 ether, 1);

        vault.updateStabilisationFeeRate((1 * 10**16) / YEAR); // 1%
        vm.warp(block.timestamp + YEAR);
        assertApproxEqual(vault.getOverallDebt(vaultId), 1649 ether, 1);
        vault.updateStabilisationFeeRate((5 * 10**16) / YEAR); // 5%
        vm.warp(block.timestamp + YEAR);
        assertApproxEqual(vault.getOverallDebt(vaultId), 1731.45 ether, 1);

        vault.checkInvariantOnVault(vaultId);
        vault.burnDebt(vaultId, 900 ether);
        assertApproxEqual(vault.getOverallDebt(vaultId), 831.45 ether, 1);

        vault.checkInvariantOnVault(vaultId);
        vault.updateStabilisationFeeRate(0); // 0%
        vm.warp(block.timestamp + 10 * YEAR);
        assertApproxEqual(vault.getOverallDebt(vaultId), 831.45 ether, 1);

        deal(address(token), address(this), 833 ether, true);
        vault.checkInvariantOnVault(vaultId);
        vault.burnDebt(vaultId, vault.getOverallDebt(vaultId));
        vault.checkInvariantOnVault(vaultId);
        vault.closeVault(vaultId, address(this));
    }

    function testFeesUpdatedAfterSecond() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**20, 10**11, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        vault.mintDebt(vaultId, 1000 ether);
        vault.checkInvariantOnVault(vaultId);
        uint256 beforeDebt = vault.getOverallDebt(vaultId);

        vault.updateStabilisationFeeRate(10**17 / YEAR);
        vm.warp(block.timestamp + 1);

        uint256 afterDebt = vault.getOverallDebt(vaultId);
        assertTrue(beforeDebt != afterDebt);
    }

    function testFeesCalculatedProportionally() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**20, 10**11, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        vault.checkInvariantOnVault(vaultId);
        vault.mintDebt(vaultId, 1000 ether);
        uint256 beforeDebt = vault.getOverallDebt(vaultId);

        vault.checkInvariantOnVault(vaultId);
        vm.warp(block.timestamp + 3600);
        uint256 hourFee = vault.getOverallDebt(vaultId) - beforeDebt;
        vm.warp(block.timestamp + 3600 * 23);

        vault.checkInvariantOnVault(vaultId);
        uint256 dailyFee = vault.getOverallDebt(vaultId) - beforeDebt;
        assertApproxEqual(dailyFee / 24, hourFee, 1); // <0.1% delta
    }

    function testReasonablePoolFeesCalculating() public {
        uint256 vaultId = vault.openVault();
        uint256 nftA = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, nftA);

        (, , uint256 borrowLimitBefore) = vault.calculateVaultCollateral(vaultId);
        vault.mintDebt(vaultId, borrowLimitBefore - 1);
        vault.checkInvariantOnVault(vaultId);

        vm.expectRevert(Vault.PositionUnhealthy.selector);
        vault.mintDebt(vaultId, 100);

        helper.setTokenPrice(oracle, weth, 999 << 96); // small price change to make position slightly lower than health threshold
        (, , uint256 borrowLimitAfter) = vault.calculateVaultCollateral(vaultId);
        uint256 debt = vault.getOverallDebt(vaultId);

        assertTrue(borrowLimitAfter <= debt);

        for (uint256 i = 0; i < 5; i++) {
            uint256 amountOut = helper.makeSwap(weth, usdc, 10**22); // have to get a lot of fees
            helper.makeSwap(usdc, weth, amountOut);
        }

        (, , uint256 borrowLimitAfterSwaps) = vault.calculateVaultCollateral(vaultId);

        assertApproxEqual(borrowLimitBefore, borrowLimitAfterSwaps, 30); // difference < 3% though

        address liquidator = getNextUserAddress();
        deal(address(token), liquidator, 10000 ether, true);
        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(Vault.PositionHealthy.selector);
        vault.liquidate(vaultId); // hence not liquidated
        vm.stopPrank();
    }

    function testFeesUpdatedAfterAllOnlyMintBurn() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenA = helper.openPosition(weth, usdc, 10**20, 10**11, address(vault));
        uint256 tokenB = helper.openPosition(weth, usdc, 10**20, 10**11, address(vault));
        vault.depositCollateral(vaultId, tokenA);
        vault.mintDebt(vaultId, 1000 ether);

        uint256 currentDebt = vault.getOverallDebt(vaultId);

        vm.warp(block.timestamp + YEAR);
        vault.mintDebt(vaultId, 0);
        uint256 newDebt = vault.getOverallDebt(vaultId);
        assertTrue(currentDebt < newDebt);
        currentDebt = newDebt;
        vault.checkInvariantOnVault(vaultId);

        vm.warp(block.timestamp + YEAR);
        vault.burnDebt(vaultId, 0);
        newDebt = vault.getOverallDebt(vaultId);
        assertTrue(currentDebt < newDebt);
        currentDebt = newDebt;
        vault.checkInvariantOnVault(vaultId);

        vm.warp(block.timestamp + YEAR); // +1%
        vault.depositCollateral(vaultId, tokenB);
        newDebt = vault.getOverallDebt(vaultId);
        assertApproxEqual((currentDebt * 101) / 100, newDebt, 1);
        currentDebt = newDebt;
        vault.checkInvariantOnVault(vaultId);

        vm.warp(block.timestamp + YEAR); // +1%
        vault.withdrawCollateral(tokenB);
        newDebt = vault.getOverallDebt(vaultId);
        assertApproxEqual((currentDebt * 101) / 100, newDebt, 1);
        vault.checkInvariantOnVault(vaultId);
    }

    function testLiquidationThresholdChangedHenceLiquidated() public {
        uint256 vaultId = vault.openVault();

        uint256 nftA = helper.openPosition(weth, usdc, 10**19, 10**10, address(vault)); // 20000 USD
        vault.depositCollateral(vaultId, nftA);
        vault.mintDebt(vaultId, 10000 * (10**18));
        vault.checkInvariantOnVault(vaultId);

        address pool = helper.getPool(weth, usdc);

        vault.setPoolParams(pool, ICDP.PoolParams(0.2 gwei, 0.2 gwei, 0));
        vault.burnDebt(vaultId, 5000 * (10**18)); // repaid debt partially and anyway liquidated
        vault.checkInvariantOnVault(vaultId);

        address liquidator = getNextUserAddress();
        deal(address(token), liquidator, 100000 ether, true);
        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);
        vault.liquidate(vaultId);
        vault.checkInvariantOnVault(vaultId);
        vm.stopPrank();
    }
}
