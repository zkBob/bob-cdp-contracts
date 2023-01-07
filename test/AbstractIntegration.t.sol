// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@zkbob/proxy/EIP1967Proxy.sol";
import "../src/Vault.sol";
import "../src/VaultRegistry.sol";

import "./SetupContract.sol";
import "./mocks/BobTokenMock.sol";
import "./mocks/MockOracle.sol";
import "./shared/ForkTests.sol";

abstract contract AbstractIntegrationTestForVault is SetupContract, AbstractForkTest, AbstractLateSetup {
    IMockOracle oracle;
    BobTokenMock token;
    Vault vault;
    VaultRegistry vaultRegistry;
    INFTOracle nftOracle;
    EIP1967Proxy vaultProxy;
    EIP1967Proxy vaultRegistryProxy;
    EIP1967Proxy nftOracleProxy;
    INonfungiblePositionManager positionManager;
    address treasury;

    uint256 YEAR = 365 * 24 * 60 * 60;

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

        vaultRegistry = new VaultRegistry(ICDP(address(vault)), "BOB Vault Token", "BVT", "");

        vaultRegistryProxy = new EIP1967Proxy(address(this), address(vaultRegistry), "");
        vaultRegistry = VaultRegistry(address(vaultRegistryProxy));

        vault.setVaultRegistry(IVaultRegistry(address(vaultRegistry)));

        token.updateMinter(address(vault), true, true);
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
    }

    // integration scenarios

    function testMultipleDepositAndWithdrawsSuccessSingleVault() public {
        uint256 vaultId = vault.openVault();
        uint256 nftA = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault)); // 2000 USD
        uint256 nftB = helper.openPosition(wbtc, usdc, 5 * 10**8, 100000 * 10**6, address(vault)); // 200000 USD
        (, uint256 wbtcPriceX96) = oracle.price(wbtc);
        (, uint256 wethPriceX96) = oracle.price(weth);
        helper.makeDesiredPoolPrice(FullMath.mulDiv(wbtcPriceX96, Q96, wethPriceX96), wbtc, weth);
        uint256 nftC = helper.openPosition(wbtc, weth, 10**8 / 20000, 10**18 / 1000, address(vault)); // 2 USD

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
        uint256 nft = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, nft);
        vault.mintDebt(vaultId, 100 * 10**18);

        positionManager.transferFrom(address(vault), address(this), nft);
    }

    function testSeveralVaultsPerAddress() public {
        uint256 vaultA = vault.openVault();
        uint256 vaultB = vault.openVault();

        uint256 nftA = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        uint256 nftB = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));

        vault.depositCollateral(vaultA, nftA);
        vault.depositCollateral(vaultB, nftB);

        vault.mintDebt(vaultA, 1000 * 10**18);
        vault.mintDebt(vaultB, 1 * 10**18);

        // bankrupt first vault

        helper.setTokenPrice(oracle, weth, 400 << 96);
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
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        uint256 secondNft = helper.openPosition(weth, usdc, 10**18, 10**9, secondAddress);

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
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1000 * 10**18);
        // eth 1000 -> 800
        helper.setTokenPrice(oracle, weth, 800 << 96);

        (, uint256 healthFactor) = vault.calculateVaultCollateral(vaultId);
        uint256 overallDebt = vault.vaultDebt(vaultId) + vault.stabilisationFeeVaultSnapshot(vaultId);
        assertTrue(healthFactor <= overallDebt); // hence subject to liquidation

        helper.setTokenPrice(oracle, weth, 1200 << 96); // price got back

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
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
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
            uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
            vault.depositCollateral(vaultId, tokenId);
            vault.mintDebt(vaultId, 1000 * 10**18);
            helper.setTokenPrice(oracle, weth, 800 << 96);

            address liquidator = getNextUserAddress();
            deal(address(token), liquidator, 10000 * 10**18, true);

            vm.startPrank(liquidator);
            token.approve(address(vault), type(uint256).max);
            vault.liquidate(vaultId); // liquidated

            uint256 newTreasuryBalance = token.balanceOf(treasury);
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
        uint256 tokenId = helper.openPosition(weth, usdc, 10**20, 10**11, address(vault));
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
        uint256 tokenId = helper.openPosition(weth, usdc, 10**20, 10**11, address(vault));
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
        uint256 tokenA = helper.openPosition(weth, usdc, 10**20, 10**11, address(vault));
        uint256 tokenB = helper.openPosition(weth, usdc, 10**20, 10**11, address(vault));
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

    function LiquidationThresholdChangedHenceLiquidated() public {
        uint256 vaultId = vault.openVault();

        uint256 nftA = helper.openPosition(weth, usdc, 10**19, 10**10, address(vault)); // 20000 USD
        vault.depositCollateral(vaultId, nftA);
        vault.mintDebt(vaultId, 10000 * (10**18));

        address pool = helper.getPool(weth, usdc);

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
