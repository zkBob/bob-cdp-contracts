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

contract VaultTest is Test, SetupContract, Utilities {
    event VaultOpened(address indexed origin, address indexed sender, uint256 vaultId);
    event VaultLiquidated(address indexed origin, address indexed sender, uint256 vaultId);
    event VaultClosed(address indexed origin, address indexed sender, uint256 vaultId);

    event CollateralDeposited(address indexed origin, address indexed sender, uint256 vaultId, uint256 nft);
    event CollateralWithdrew(address indexed origin, address indexed sender, uint256 vaultId, uint256 nft);

    event DebtMinted(address indexed origin, address indexed sender, uint256 vaultId, uint256 amount);
    event DebtBurned(address indexed origin, address indexed sender, uint256 vaultId, uint256 amount);

    event StabilisationFeeUpdated(address indexed origin, address indexed sender, uint256 stabilisationFee);
    event OracleUpdated(address indexed origin, address indexed sender, address oracleAddress);
    event TokenUpdated(address indexed origin, address indexed sender, address oracleAddress);

    event SystemPaused(address indexed origin, address indexed sender);
    event SystemUnpaused(address indexed origin, address indexed sender);

    event SystemPrivate(address indexed origin, address indexed sender);
    event SystemPublic(address indexed origin, address indexed sender);

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

        protocolGovernance = new ProtocolGovernance(address(this), type(uint256).max);

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
        protocolGovernance.changeMinSingleNftCollateral(10**17);

        setPools(IProtocolGovernance(protocolGovernance));
        setApprovals();

        address[] memory depositors = new address[](1);
        depositors[0] = address(this);
        vault.addDepositorsToAllowlist(depositors);
    }

    // addDepositorsToAllowlist

    function testAddDepositorsToAllowlistSuccess() public {
        address newAddress = getNextUserAddress();
        address[] memory addresses = new address[](1);
        addresses[0] = newAddress;
        vault.addDepositorsToAllowlist(addresses);
        address[] memory depositors = vault.depositorsAllowlist();
        assertEq(getLength(depositors), 2);
        assertEq(address(this), depositors[0]);
        assertEq(newAddress, depositors[1]);
    }

    // removeDepositorsFromAllowlist

    function testRemoveDepositorsFromAllowlistSuccess() public {
        address[] memory addresses = new address[](1);
        addresses[0] = address(this);
        vault.removeDepositorsFromAllowlist(addresses);
        address[] memory depositors = vault.depositorsAllowlist();
        assertEq(getLength(depositors), 0);
    }

    // openVault

    function testOpenVaultSuccess() public {
        uint256 oldLen = getLength(vault.ownedVaultsByAddress(address(this)));
        vault.openVault();
        uint256 currentLen = getLength(vault.ownedVaultsByAddress(address(this)));
        assertEq(oldLen + 1, currentLen);
        vault.openVault();
        uint256 finalLen = getLength(vault.ownedVaultsByAddress(address(this)));
        assertEq(oldLen + 2, finalLen);
    }

    function testOpenVaultWhenForbidden() public {
        vm.expectRevert(Vault.AllowList.selector);

        address newAddress = getNextUserAddress();
        vm.prank(newAddress);

        vault.openVault();
    }

    function testOpenVaultEmit() public {
        vm.expectEmit(false, true, false, true);
        emit VaultOpened(getNextUserAddress(), address(this), vault.vaultCount() + 1);
        vault.openVault();
    }

    // depositCollateral

    function testDepositCollateralSuccess() public {
        uint256 vaultId = vault.openVault();

        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));

        vault.depositCollateral(vaultId, tokenId);

        uint256[] memory vaultNfts = vault.vaultNftsById(vaultId);
        assertEq(getLength(vaultNfts), 1);
        assertEq(vaultNfts[0], tokenId);
    }

    function testFailDepositCollateralNotApproved() public {
        uint256 vaultId = vault.openVault();

        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));

        vault.depositCollateral(vaultId, tokenId);
        vault.withdrawCollateral(tokenId);
        vault.depositCollateral(vaultId, tokenId); //not approved
    }

    function testFailTryDepositTwice() public {
        uint256 vaultId = vault.openVault();

        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.depositCollateral(vaultId, tokenId);
    }

    function testDepositCollateralWhenForbidden() public {
        vm.expectRevert(Vault.AllowList.selector);

        vm.prank(getNextUserAddress());
        vault.depositCollateral(21, 22);
    }

    function testDepositCollateralWhenNotOwner() public {
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);

        vault.depositCollateral(21, 22);
    }

    function testDepositCollateralInvalidPool() public {
        uint256 vaultId = vault.openVault();

        uint256 tokenId = openUniV3Position(weth, ape, 10**18, 10**25, address(vault));

        vm.expectRevert(Vault.InvalidPool.selector);
        vault.depositCollateral(vaultId, tokenId);
    }

    function testDepositCollateralWhenPositionDoesNotExceedMinCapital() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**10, 10**5, address(vault));

        vm.expectRevert(Vault.CollateralUnderflow.selector);
        vault.depositCollateral(vaultId, tokenId);
    }

    function testDepositCollateralWhenPositionExceedsMinCapitalButEstimationNotSuccess() public {
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        protocolGovernance.setLiquidationThreshold(pool, 10**7); // 1%
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**15, 10**6, address(vault));

        vault.depositCollateral(vaultId, tokenId);
    }

    function testDepositCollateralWhenExceedsMaxCollateralSupplyToken0() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        protocolGovernance.setTokenLimit(weth, 10**10);

        vm.expectRevert(abi.encodeWithSelector(Vault.CollateralTokenOverflow.selector, weth));
        vault.depositCollateral(vaultId, tokenId);
    }

    function testDepositCollateralWhenExceedsMaxCollateralSupplyToken1() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        protocolGovernance.setTokenLimit(usdc, 10**3);

        vm.expectRevert(abi.encodeWithSelector(Vault.CollateralTokenOverflow.selector, usdc));
        vault.depositCollateral(vaultId, tokenId);
    }

    function testDepositCollateralWhenPaused() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));

        vault.pause();

        vm.expectRevert(Vault.Paused.selector);
        vault.depositCollateral(vaultId, tokenId);
    }

    function testDepositCollateralEmit() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));

        vm.expectEmit(false, true, false, true);
        emit CollateralDeposited(getNextUserAddress(), address(this), vaultId, tokenId);
        vault.depositCollateral(vaultId, tokenId);
    }

    // closeVault

    function testCloseVaultSuccess() public {
        uint256 vaultId = vault.openVault();
        vault.closeVault(vaultId);
        assertEq(getLength(vault.ownedVaultsByAddress(address(this))), 0);
    }

    function testCloseVaultSuccessWithCollaterals() public {
        uint256 vaultId = vault.openVault();

        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        vault.closeVault(vaultId);

        assertEq(getLength(vault.ownedVaultsByAddress(address(this))), 0);
        assertEq(positionManager.ownerOf(tokenId), address(this));
    }

    function testClosedVaultNotAcceptingAnything() public {
        uint256 vaultId = vault.openVault();
        vault.closeVault(vaultId);

        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        vault.depositCollateral(vaultId, 123);
    }

    function testCloseWithUnpaidDebt() public {
        uint256 vaultId = vault.openVault();

        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 10);

        vm.expectRevert(Vault.UnpaidDebt.selector);
        vault.closeVault(vaultId);
    }

    function testCloseVaultWithUnpaidFees() public {
        uint256 vaultId = vault.openVault();

        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1000 * 10**18);

        vm.warp(block.timestamp + YEAR);
        vault.burnDebt(vaultId, 1000 * 10**18);

        vm.expectRevert(Vault.UnpaidDebt.selector);
        vault.closeVault(vaultId);
    }

    function testCloseVaultWrongOwner() public {
        uint256 vaultId = vault.openVault();
        vm.prank(getNextUserAddress());
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        vault.closeVault(vaultId);
    }

    function testCloseVaultEmit() public {
        uint256 vaultId = vault.openVault();

        vm.expectEmit(false, true, false, true);
        emit VaultClosed(getNextUserAddress(), address(this), vaultId);
        vault.closeVault(vaultId);
    }

    // mintDebt

    function testMintDebtSuccess() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 10);
        assertEq(token.balanceOf(address(this)), 10);
    }

    function testMintDebtPaused() public {
        vault.pause();
        vm.expectRevert(Vault.Paused.selector);
        vault.mintDebt(1, 1);
    }

    function testMintDebtWhenNotOwner() public {
        uint256 vaultId = vault.openVault();
        vm.prank(getNextUserAddress());
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        vault.mintDebt(vaultId, 1);
    }

    function testMintDebtWhenPositionUnhealthy() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        vm.expectRevert(Vault.PositionUnhealthy.selector);
        vault.mintDebt(vaultId, type(uint256).max);
    }

    function testMintDebtEmit() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        vm.expectEmit(false, true, false, true);
        emit DebtMinted(getNextUserAddress(), address(this), vaultId, 10);

        vault.mintDebt(vaultId, 10);
    }

    // burnDebt

    function testBurnDebtSuccess() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 10);
        vault.burnDebt(vaultId, 10);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function testBurnMoreThanDebtSuccess() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 10);
        vault.burnDebt(vaultId, 1000);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function testFailBurnMoreThanBalance() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1000);
        vm.warp(block.timestamp + YEAR);
        vault.burnDebt(vaultId, 1003);
    }

    function testFailBurnAfterTransferPartOfBalance() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1000);

        address receiver = getNextUserAddress();
        token.transfer(receiver, 500);

        vault.burnDebt(vaultId, 600);
    }

    function testPartialBurnSuccess() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 300 * 10**18);
        vm.warp(block.timestamp + YEAR);

        vault.burnDebt(vaultId, 150 * 10**18);
        assertEq(token.balanceOf(address(this)), 150 * 10**18);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(vault.stabilisationFeeVaultSnapshot(vaultId), 3 * 10**18);
        assertEq(vault.vaultDebt(vaultId), 150 * 10**18);
    }

    function testPartialFeesBurnSuccess() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 300 * 10**18);
        vm.warp(block.timestamp + YEAR);

        deal(address(token), address(this), 303 * 10**18);
        vault.burnDebt(vaultId, 302 * 10**18);

        assertEq(token.balanceOf(address(this)), 1 * 10**18);
        assertEq(token.balanceOf(treasury), 2 * 10**18);
        assertEq(vault.stabilisationFeeVaultSnapshot(vaultId), 10**18);
        assertEq(vault.vaultDebt(vaultId), 0);
    }

    function testBurnDebtSuccessWithFees() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 300 * 10**18);
        vm.warp(block.timestamp + YEAR);
        uint256 overallDebt = vault.getOverallDebt(vaultId);
        assertEq(overallDebt, 303 * 10**18); // +1%
        // setting balance manually assuming that we'll swap tokens on DEX
        deal(address(token), address(this), 303 * 10**18);
        vault.burnDebt(vaultId, overallDebt);

        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(treasury), 3 * 10**18);
    }

    function testBurnDebtWhenPaused() public {
        vault.pause();
        vm.expectRevert(Vault.Paused.selector);
        vault.burnDebt(1, 1);
    }

    function testBurnDebtWhenNotOwner() public {
        uint256 vaultId = vault.openVault();
        vm.prank(getNextUserAddress());
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        vault.burnDebt(vaultId, 1);
    }

    function testBurnDebtEmit() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        vault.mintDebt(vaultId, 10);

        vm.expectEmit(false, true, false, true);
        emit DebtBurned(getNextUserAddress(), address(this), vaultId, 10);

        vault.burnDebt(vaultId, 10);
    }

    // withdrawCollateral

    function testWithdrawCollateralSuccess() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.withdrawCollateral(tokenId);
        assertEq(getLength(vault.vaultNftsById(vaultId)), 0);
        assertEq(positionManager.ownerOf(tokenId), address(this));
    }

    function testWithdrawCollateralWhenPaused() public {
        vault.pause();
        vm.expectRevert(Vault.Paused.selector);
        vault.withdrawCollateral(1);
    }

    function testWithdrawCollateralWhenNotOwner() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        vm.prank(getNextUserAddress());
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        vault.withdrawCollateral(tokenId);
    }

    function testWithdrawCollateralWhenPositionGoingUnhealthy() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1);
        vm.expectRevert(Vault.PositionUnhealthy.selector);
        vault.withdrawCollateral(tokenId);
    }

    function testWithdrawCollateralEmit() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vm.expectEmit(false, true, false, true);
        emit CollateralWithdrew(getNextUserAddress(), address(this), vaultId, tokenId);
        vault.withdrawCollateral(tokenId);
    }

    // health factor

    function testHealthFactorSuccess() public {
        uint256 vaultId = vault.openVault();
        uint256 health = vault.calculateVaultAdjustedCollateral(vaultId);
        assertEq(health, 0);
    }

    function testHealthFactorAfterDeposit() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        uint256 lowCapitalBound = 10**18 * 1100;
        uint256 upCapitalBound = 10**18 * 1300; // health apparently ~1200USD
        vault.depositCollateral(vaultId, tokenId);
        uint256 health = vault.calculateVaultAdjustedCollateral(vaultId);
        assertTrue(health >= lowCapitalBound && health <= upCapitalBound);
    }

    function testHealthFactorAfterDepositWithdraw() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.withdrawCollateral(tokenId);
        uint256 health = vault.calculateVaultAdjustedCollateral(vaultId);
        assertEq(health, 0);
    }

    function testHealthFactorMultipleDeposits() public {
        uint256 vaultId = vault.openVault();
        uint256 nftA = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        uint256 nftB = openUniV3Position(wbtc, weth, 10**8, 10**18 * 20, address(vault));
        vault.depositCollateral(vaultId, nftA);
        uint256 healthOneAsset = vault.calculateVaultAdjustedCollateral(vaultId);
        vault.depositCollateral(vaultId, nftB);
        uint256 healthTwoAssets = vault.calculateVaultAdjustedCollateral(vaultId);
        vault.withdrawCollateral(nftB);
        uint256 healthOneAssetFinal = vault.calculateVaultAdjustedCollateral(vaultId);

        assertEq(healthOneAsset, healthOneAssetFinal);
        assertTrue(healthOneAsset < healthTwoAssets);
    }

    function testHealthFactorAfterPriceChange() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        uint256 healthPreAction = vault.calculateVaultAdjustedCollateral(vaultId);
        oracle.setPrice(weth, 800 << 96);
        uint256 healthLowPrice = vault.calculateVaultAdjustedCollateral(vaultId);
        oracle.setPrice(weth, 2000 << 96);
        uint256 healthHighPrice = vault.calculateVaultAdjustedCollateral(vaultId);

        assertTrue(healthLowPrice < healthPreAction);
        assertTrue(healthPreAction < healthHighPrice);
    }

    function testHealthFactorAfterPoolChange() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        uint256 healthPreAction = vault.calculateVaultAdjustedCollateral(vaultId);
        makeSwap(weth, usdc, 10**18);
        uint256 healthPostAction = vault.calculateVaultAdjustedCollateral(vaultId);
        assertTrue(healthPreAction != healthPostAction);
        assertApproxEqual(healthPreAction, healthPostAction, 1);
    }

    function testHealthFactorAfterThresholdChange() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);

        protocolGovernance.setLiquidationThreshold(pool, 1e8);
        uint256 lowCapitalBound = 10**18 * 150;
        uint256 upCapitalBound = 10**18 * 250; // health apparently ~200USD
        uint256 health = vault.calculateVaultAdjustedCollateral(vaultId);
        assertTrue(health >= lowCapitalBound && health <= upCapitalBound);

        protocolGovernance.revokeWhitelistedPool(pool);
        uint256 healthNoAssets = vault.calculateVaultAdjustedCollateral(vaultId);
        assertEq(healthNoAssets, 0);
    }

    function testHealthFactorFromRandomAddress() public {
        uint256 vaultId = vault.openVault();
        vm.prank(getNextUserAddress());
        uint256 health = vault.calculateVaultAdjustedCollateral(vaultId);
        assertEq(health, 0);
    }

    function testHealthFactorNonExistingVault() public {
        uint256 nextId = vault.vaultCount();
        uint256 health = vault.calculateVaultAdjustedCollateral(nextId);
        assertEq(health, 0);
    }

    // liquidate

    function testLiquidateSuccess() public {
        uint256 vaultId = vault.openVault();
        // overall ~2000$ -> HF: ~1200$
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1100 * 10**18);
        // eth 1000 -> 800
        oracle.setPrice(weth, 800 << 96);

        address randomAddress = getNextUserAddress();
        token.transfer(randomAddress, vault.vaultDebt(vaultId));

        uint256 health = vault.calculateVaultAdjustedCollateral(vaultId);
        uint256 debt = vault.vaultDebt(vaultId) + vault.stabilisationFeeVaultSnapshot(vaultId);

        assertTrue(health < debt);
        vm.warp(block.timestamp + 3600);

        address liquidator = getNextUserAddress();

        deal(address(token), liquidator, 2000 * 10**18, true);
        uint256 oldLiquidatorBalance = token.balanceOf(liquidator);
        uint256 debtToBeRepaid = vault.vaultDebt(vaultId);

        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);
        vault.liquidate(vaultId);
        vm.stopPrank();

        uint256 liquidatorSpent = oldLiquidatorBalance - token.balanceOf(liquidator);

        uint256 targetTreasuryBalance = (1600 * 10**18 * protocolGovernance.protocolParams().liquidationFeeD) / 10**9;
        uint256 treasuryGot = token.balanceOf(address(treasury));

        assertApproxEqual(targetTreasuryBalance, treasuryGot, 150);
        assertEq(positionManager.ownerOf(tokenId), liquidator);

        uint256 lowerBoundRemaning = 100 * 10**18;
        uint256 gotBack = token.balanceOf(address(this));

        assertTrue(lowerBoundRemaning <= gotBack);
        assertEq(gotBack + debtToBeRepaid + treasuryGot, liquidatorSpent);

        assertEq(vault.vaultDebt(vaultId), 0);
        assertEq(vault.stabilisationFeeVaultSnapshot(vaultId), 0);
    }

    function testFailLiquidateWithSmallAmount() public {
        uint256 vaultId = vault.openVault();
        // overall ~2000$ -> HF: ~1200$
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1100 * 10**18);
        // eth 1000 -> 800
        oracle.setPrice(weth, 800 << 96);

        address liquidator = getNextUserAddress();
        deal(address(token), liquidator, 2000 * 10**18, true);

        vm.startPrank(liquidator);
        token.approve(address(vault), vault.vaultDebt(vaultId)); //too small for liquidating
        vault.liquidate(vaultId);
    }

    function testLiquidateWhenPositionHealthy() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));

        uint256 health = vault.calculateVaultAdjustedCollateral(vaultId);
        uint256 debt = vault.vaultDebt(vaultId) + vault.stabilisationFeeVaultSnapshot(vaultId);

        assertTrue(debt <= health);

        vault.depositCollateral(vaultId, tokenId);
        vm.expectRevert(Vault.PositionHealthy.selector);
        vault.liquidate(vaultId);
    }

    function testLiquidateEmit() public {
        uint256 vaultId = vault.openVault();
        // overall ~2000$ -> HF: ~1200$
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1100 * 10**18);
        // eth 1000 -> 800
        oracle.setPrice(weth, 800 << 96);

        uint256 health = vault.calculateVaultAdjustedCollateral(vaultId);
        uint256 debt = vault.vaultDebt(vaultId) + vault.stabilisationFeeVaultSnapshot(vaultId);

        assertTrue(health < debt);

        address liquidator = getNextUserAddress();

        deal(address(token), liquidator, 2000 * 10**18, true);

        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);

        vm.expectEmit(false, true, false, true);
        emit VaultLiquidated(getNextUserAddress(), liquidator, vaultId);
        vault.liquidate(vaultId);
        vm.stopPrank();
    }

    // makePublic

    function testMakePublicSuccess() public {
        vault.makePublic();
        assertEq(vault.isPrivate(), false);
    }

    function testMakePublicWhenNotAdmin() public {
        vm.prank(getNextUserAddress());
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        vault.makePublic();
    }

    function testMakePublicEmit() public {
        vm.expectEmit(false, true, false, false);
        emit SystemPublic(getNextUserAddress(), address(this));
        vault.makePublic();
    }

    // makePrivate

    function testMakePrivateSuccess() public {
        vault.makePrivate();
        assertEq(vault.isPrivate(), true);
    }

    function testMakePrivateWhenNotAdmin() public {
        vm.prank(getNextUserAddress());
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        vault.makePrivate();
    }

    function testMakePrivateEmit() public {
        vm.expectEmit(false, true, false, false);
        emit SystemPrivate(getNextUserAddress(), address(this));
        vault.makePrivate();
    }

    // pause

    function testPauseSuccess() public {
        vault.pause();
        assertEq(vault.isPaused(), true);
    }

    function testPauseWhenOperator() public {
        address operator = getNextUserAddress();
        vault.grantRole(keccak256("admin_delegate"), address(this));
        vault.grantRole(keccak256("operator"), operator);
        vm.prank(operator);
        vault.pause();
        assertEq(vault.isPaused(), true);
    }

    function testPauseWhenNotAdmin() public {
        vm.prank(getNextUserAddress());
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        vault.pause();
    }

    function testPauseEmit() public {
        vm.expectEmit(false, true, false, false);
        emit SystemPaused(getNextUserAddress(), address(this));
        vault.pause();
    }

    // unpause

    function testUnpauseSuccess() public {
        vault.pause();
        vault.unpause();
        assertEq(vault.isPaused(), false);
    }

    function testUnpauseWhenOperator() public {
        address operator = getNextUserAddress();
        vault.grantRole(keccak256("admin_delegate"), address(this));
        vault.grantRole(keccak256("operator"), operator);
        vm.prank(operator);
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        vault.unpause();
    }

    function testUnpauseWhenNotAdmin() public {
        vm.prank(getNextUserAddress());
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        vault.unpause();
    }

    function testUnpauseEmit() public {
        vm.expectEmit(false, true, false, false);
        emit SystemUnpaused(getNextUserAddress(), address(this));
        vault.unpause();
    }

    // setToken

    function testSetTokenSuccess() public {
        Vault newVault = new Vault(
            address(this),
            INonfungiblePositionManager(UniV3PositionManager),
            IUniswapV3Factory(UniV3Factory),
            IProtocolGovernance(protocolGovernance),
            IOracle(oracle),
            treasury,
            10**7
        );
        address newAddress = getNextUserAddress();
        newVault.setToken(IMUSD(newAddress));
        assertEq(address(newVault.token()), newAddress);
    }

    function testSetTokenWhenNotAdmin() public {
        vm.prank(getNextUserAddress());
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        vault.setToken(IMUSD(getNextUserAddress()));
    }

    function testSetTokenWhenAddressZero() public {
        vm.expectRevert(DefaultAccessControl.AddressZero.selector);
        vault.setToken(IMUSD(address(0)));
    }

    function testSetTokenWhenTokenSet() public {
        vm.expectRevert(Vault.TokenSet.selector);
        vault.setToken(IMUSD(getNextUserAddress()));
    }

    function testSetTokenEmit() public {
        Vault newVault = new Vault(
            address(this),
            INonfungiblePositionManager(UniV3PositionManager),
            IUniswapV3Factory(UniV3Factory),
            IProtocolGovernance(protocolGovernance),
            IOracle(oracle),
            treasury,
            10**7
        );
        address newAddress = getNextUserAddress();
        vm.expectEmit(false, true, false, true);
        emit TokenUpdated(tx.origin, address(this), newAddress);
        newVault.setToken(IMUSD(newAddress));
    }

    // setOracle

    function testSetOracleSuccess() public {
        address newAddress = getNextUserAddress();
        vault.setOracle(IOracle(newAddress));
        assertEq(address(vault.oracle()), newAddress);
    }

    function testSetOracleWhenNotAdmin() public {
        vm.prank(getNextUserAddress());
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        vault.setOracle(IOracle(getNextUserAddress()));
    }

    function testSetOracleWhenAddressZero() public {
        vm.expectRevert(DefaultAccessControl.AddressZero.selector);
        vault.setOracle(IOracle(address(0)));
    }

    function testSetOracleEmit() public {
        address newAddress = getNextUserAddress();
        vm.expectEmit(false, true, false, true);
        emit OracleUpdated(tx.origin, address(this), newAddress);
        vault.setOracle(IOracle(newAddress));
    }

    // ownedVaultsByAddress

    function testOwnedVaultsByAddress() public {
        assertEq(getLength(vault.ownedVaultsByAddress(address(this))), 0);
        uint256 vaultId = vault.openVault();
        uint256[] memory vaults = vault.ownedVaultsByAddress(address(this));
        assertEq(getLength(vaults), 1);
        assertEq(vaults[0], vaultId);
    }

    // vaultNftsById

    function testVaultNftsByIdSuccess() public {
        uint256 vaultId = vault.openVault();
        assertEq(getLength(vault.vaultNftsById(vaultId)), 0);
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        uint256[] memory nfts = vault.vaultNftsById(vaultId);
        assertEq(getLength(nfts), 1);
        assertEq(nfts[0], tokenId);
    }

    // getOverallDebt

    function testOverallDebtSuccess() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 300 * 10**18);
        uint256 overallDebt = vault.getOverallDebt(vaultId);
        assertEq(overallDebt, 300 * 10**18);
    }

    function testOverallDebtSuccessWithFees() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 300 * 10**18);
        vm.warp(block.timestamp + YEAR); // 1 YEAR
        uint256 overallDebt = vault.getOverallDebt(vaultId);
        assertEq(overallDebt, 303 * 10**18); // +1%
    }

    // updateStabilisationFeeRate

    function testUpdateStabilisationFeeSuccess() public {
        vault.updateStabilisationFeeRate(2 * 10**7);
        assertEq(vault.stabilisationFeeRateD(), 2 * 10**7);
    }

    function testUpdateStabilisationFeeSuccessWithCalculations() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = openUniV3Position(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 300 * 10**18);
        vm.warp(block.timestamp + YEAR);
        uint256 overallDebt = vault.getOverallDebt(vaultId);
        assertEq(overallDebt, 303 * 10**18); // +1%
        vault.updateStabilisationFeeRate(10 * 10**7);
        vm.warp(block.timestamp + YEAR);
        overallDebt = vault.getOverallDebt(vaultId);
        assertEq(overallDebt, 333 * 10**18); // +1% per first year and +10% per second year
    }

    function testUpdateStabilisationFeeWhenNotAdmin() public {
        vm.prank(getNextUserAddress());
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        vault.updateStabilisationFeeRate(10**7);
    }

    function testUpdateStabilisationFeeWithInvalidValue() public {
        vm.expectRevert(Vault.InvalidValue.selector);
        vault.updateStabilisationFeeRate(10**12);
    }

    function testUpdateStabilisationFeeEmit() public {
        vm.expectEmit(false, true, false, true);
        emit StabilisationFeeUpdated(getNextUserAddress(), address(this), 2 * 10**7);
        vault.updateStabilisationFeeRate(2 * 10**7);
    }
}
