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

contract IntegrationTestForVault is Test, SetupContract, Utilities {
    MockOracle oracle;
    ProtocolGovernance protocolGovernance;
    MUSD token;
    Vault vault;
    INonfungiblePositionManager positionManager;
    address treasury;

    uint256 YEAR = 365 * 24 * 60 * 60;

    function setUp() public {
        positionManager = INonfungiblePositionManager(UniV3PositionManager);

        oracle = new MockOracle();

        oracle.setPrice(wbtc, uint256(20000 << 96) * uint256(10**10));
        oracle.setPrice(weth, uint256(1000 << 96));
        oracle.setPrice(usdc, uint256(1 << 96) * uint256(10**12));

        protocolGovernance = new ProtocolGovernance(address(this));

        treasury = getNextUserAddress();

        vault = new Vault(
            address(this),
            INonfungiblePositionManager(UniV3PositionManager),
            IUniswapV3Factory(UniV3Factory),
            IProtocolGovernance(protocolGovernance),
            IOracle(oracle),
            treasury,
            10**7
        );

        token = new MUSD("Mellow USD", "MUSD", address(vault));
        vault.setToken(IMUSD(address(token)));

        protocolGovernance.changeLiquidationFee(3 * 10**7);
        protocolGovernance.changeLiquidationPremium(3 * 10**7);
        protocolGovernance.changeMinSingleNftCapital(10**17);

        setPools(IProtocolGovernance(protocolGovernance));
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
        uint256 nftC = openUniV3Position(wbtc, weth, 10**8 / 20000, 10**18 / 1000, address(vault)); // 2 USD

        protocolGovernance.changeMinSingleNftCapital(18 * 10**17);

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

        protocolGovernance.changeMinSingleNftCapital(18 * 10**20);
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

        oracle.setPrice(weth, 200 << 96);
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

        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        vault.closeVault(vaultA);
        vm.expectRevert(Vault.UnpaidDebt.selector);
        vault.closeVault(vaultB);
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

        vault.mintDebt(vaultId, 1100 * 10**18);
        vm.startPrank(secondAddress);

        positionManager.approve(address(vault), secondNft);
        uint256 secondVault = vault.openVault();
        vault.depositCollateral(secondVault, secondNft);
        vault.mintDebt(secondVault, 300 * 10**18);

        vm.stopPrank();
        vm.warp(block.timestamp + 4 * YEAR);
        assertTrue(vault.getOverallDebt(vaultId) > vault.calculateHealthFactor(vaultId));

        vm.startPrank(secondAddress);
        console.log(token.balanceOf(secondAddress));
        token.transfer(firstAddress, 300 * 10**18);
        vm.stopPrank();

        vault.burnDebt(vaultId, token.balanceOf(firstAddress));
        vault.closeVault(vaultId);
    }

    function testPriceDroppedAndGotBackNotLiquidated() public {
        uint256 vaultId = vault.openVault();
        // overall ~2000$ -> HF: ~1200$
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1100 * 10**18);
        // eth 1000 -> 800
        oracle.setPrice(weth, 800 << 96);

        uint256 healthFactor = vault.calculateHealthFactor(vaultId);
        uint256 overallDebt = vault.debt(vaultId) + vault.debtFee(vaultId);
        assertTrue(healthFactor <= overallDebt); // hence subject to liquidation

        oracle.setPrice(weth, 1200 << 96); // price got back

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

        vault.updateStabilisationFee(5 * 10**7);

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
            oracle.setPrice(weth, 400 << 96);

            address liquidator = getNextUserAddress();
            deal(address(token), liquidator, 10000 * 10**18, true);

            vm.startPrank(liquidator);
            token.approve(address(vault), type(uint256).max);
            vault.liquidate(vaultId); // liquidated

            uint256 newTreasuryBalance = token.balanceOf(treasury);
            assertTrue(oldTreasuryBalance < newTreasuryBalance);
            oldTreasuryBalance = newTreasuryBalance;

            oracle.setPrice(weth, 1000 << 96);
            vm.stopPrank();
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

        vault.updateStabilisationFee(5 * 10**7); // 5%
        vm.warp(block.timestamp + YEAR);
        assertEq(vault.getOverallDebt(vaultId), 1630 * 10**18);

        vault.updateStabilisationFee(1 * 10**7); // 1%
        vm.warp(block.timestamp + YEAR);
        assertEq(vault.getOverallDebt(vaultId), 1645 * 10**18);
        vault.updateStabilisationFee(5 * 10**7); // 5%
        vm.warp(block.timestamp + YEAR);
        assertEq(vault.getOverallDebt(vaultId), 1720 * 10**18);

        vault.burnDebt(vaultId, 900 * 10**18);
        assertEq(vault.getOverallDebt(vaultId), 820 * 10**18);

        vault.updateStabilisationFee(0); // 0%
        vm.warp(block.timestamp + 10 * YEAR);
        assertEq(vault.getOverallDebt(vaultId), 820 * 10**18);

        deal(address(token), address(this), 820 * 10**18, true);
        vault.burnDebt(vaultId, 820 * 10**18);
        vault.closeVault(vaultId);
    }

    function testFeesUpdatedAfterSecond() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**20, 10**11, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        vault.mintDebt(vaultId, 1000 * 10**18);
        uint256 beforeDebt = vault.getOverallDebt(vaultId);

        vault.updateStabilisationFee(1);
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

        vm.warp(block.timestamp + 1);
        uint256 secondFee = vault.getOverallDebt(vaultId) - beforeDebt;
        vm.warp(block.timestamp + 59);

        uint256 minuteFee = vault.getOverallDebt(vaultId) - beforeDebt;
        assertEq(secondFee, minuteFee / 60);
    }

    function testFeesUpdatedAfterAllOperations() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenA = openUniV3Position(weth, usdc, 10**20, 10**11, address(vault));
        uint256 tokenB = openUniV3Position(weth, usdc, 10**20, 10**11, address(vault));
        vault.depositCollateral(vaultId, tokenA);
        vault.mintDebt(vaultId, 1000 * 10**18);

        uint256 currentDebt = vault.debtFee(vaultId);

        vm.warp(block.timestamp + YEAR);
        vault.mintDebt(vaultId, 0);
        uint256 newDebt = vault.debtFee(vaultId);
        assertTrue(currentDebt < newDebt);
        currentDebt = newDebt;

        vm.warp(block.timestamp + YEAR);
        vault.burnDebt(vaultId, 0);
        newDebt = vault.debtFee(vaultId);
        assertTrue(currentDebt < newDebt);
        currentDebt = newDebt;

        vm.warp(block.timestamp + YEAR);
        vault.depositCollateral(vaultId, tokenB);
        newDebt = vault.debtFee(vaultId);
        assertTrue(currentDebt < newDebt);
        currentDebt = newDebt;

        vm.warp(block.timestamp + YEAR);
        vault.withdrawCollateral(tokenB);
        newDebt = vault.debtFee(vaultId);
        assertTrue(currentDebt < newDebt);
    }

    function testReasonablePoolFeesCalculating() public {
        uint256 vaultId = vault.openVault();
        uint256 nftA = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, nftA);

        uint256 healthBeforeSwaps = vault.calculateHealthFactor(vaultId);
        vault.mintDebt(vaultId, healthBeforeSwaps - 1);

        vm.expectRevert(Vault.PositionUnhealthy.selector);
        vault.mintDebt(vaultId, 100);

        oracle.setPrice(weth, (uint256(1000 << 96) * 999999) / 1000000); // small price change to make position slightly lower than health threshold
        uint256 healthAfterPriceChanged = vault.calculateHealthFactor(vaultId);
        uint256 debt = vault.debt(vaultId);

        assertTrue(healthAfterPriceChanged <= debt);

        uint256 amountOut = makeSwap(weth, usdc, 10**22); // have to get a lot of fees
        makeSwap(usdc, weth, amountOut);

        uint256 healthAfterSwaps = vault.calculateHealthFactor(vaultId);
        assertTrue(healthBeforeSwaps * 100001 <= healthAfterSwaps * 100000);
        assertApproxEqual(healthAfterSwaps, healthBeforeSwaps, 2); // difference < 0.2% though

        address liquidator = getNextUserAddress();
        deal(address(token), liquidator, 10000 * 10**18, true);
        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(Vault.PositionHealthy.selector);
        vault.liquidate(vaultId); // hence not liquidated
        vm.stopPrank();
    }

    function testTokenGotScammedHenceLiquidated() public {
        // usdc playing a role of scammed token here
        uint256 vaultId = vault.openVault();

        protocolGovernance.setTokenLimit(usdc, 100000 * 10**6); // 100000 USD

        uint256 nftA = openUniV3Position(weth, usdc, 10**19, 10**10, address(vault)); //20000 USD
        uint256 nftB = openUniV3Position(wbtc, weth, 10**8 / 2, 10**18 * 20, address(vault)); //20000 USD

        vault.depositCollateral(vaultId, nftA);
        vault.depositCollateral(vaultId, nftB);
        vault.mintDebt(vaultId, 20000 * (10**18));

        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        protocolGovernance.revokeWhitelistedPool(pool);

        address liquidator = getNextUserAddress();
        deal(address(token), liquidator, 100000 * 10**18, true);
        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);
        vault.liquidate(vaultId);
        vm.stopPrank();
    }

    function LiquidationThresholdChangedHenceLiquidated() public {
        uint256 vaultId = vault.openVault();

        uint256 nftA = openUniV3Position(weth, usdc, 10**19, 10**10, address(vault)); // 20000 USD
        vault.depositCollateral(vaultId, nftA);
        vault.mintDebt(vaultId, 10000 * (10**18));

        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);

        protocolGovernance.setLiquidationThreshold(pool, 2 * 10**8);
        vault.burnDebt(vaultId, 5000 * (10**18)); // repaid debt partially and anyway liquidated

        address liquidator = getNextUserAddress();
        deal(address(token), liquidator, 100000 * 10**18, true);
        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);
        vault.liquidate(vaultId);
        vm.stopPrank();
    }

    function testTokenLimitDecreasedAndIncreasedBack() public {
        uint256 vaultId = vault.openVault();
        uint256 nftA = openUniV3Position(weth, usdc, 10**19, 10**10, address(vault)); // 20000 USD

        vault.depositCollateral(vaultId, nftA);
        vault.mintDebt(vaultId, 1000 * (10**18)); // 1000 USD minted

        protocolGovernance.setTokenLimit(usdc, 100 * (10**6)); // 100 USD limit set
        vault.mintDebt(vaultId, 1000 * (10**18)); // can mint more anyway

        uint256 nftB = openUniV3Position(weth, usdc, 10**19, 10**10, address(vault)); //20000 USD
        vm.expectRevert(abi.encodeWithSelector(Vault.CollateralTokenOverflow.selector, usdc));
        vault.depositCollateral(vaultId, nftB);

        protocolGovernance.setTokenLimit(usdc, 100 * (10**12)); // 100mln USD limit set
        vault.depositCollateral(vaultId, nftB);
    }
}
