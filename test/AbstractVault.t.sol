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
import "@zkbob/minters/DebtMinter.sol" as DebtMinter;
import "@zkbob/minters/SurplusMinter.sol" as TreasuryMinter;
import "./mocks/VaultMock.sol";

abstract contract AbstractVaultTest is SetupContract, AbstractForkTest, AbstractLateSetup {
    error MissingOracle();

    event VaultOpened(address indexed sender, uint256 indexed vaultId);
    event VaultLiquidated(address indexed sender, uint256 indexed vaultId);
    event VaultClosed(address indexed sender, uint256 indexed vaultId);

    event CollateralDeposited(address indexed sender, uint256 indexed vaultId, uint256 tokenId);
    event CollateralWithdrew(address indexed sender, uint256 indexed vaultId, uint256 tokenId);

    event DebtMinted(address indexed sender, uint256 indexed vaultId, uint256 amount);
    event DebtBurned(address indexed sender, uint256 indexed vaultId, uint256 amount);

    event StabilisationFeeUpdated(address indexed sender, uint256 stabilisationFee);
    event NormalizationRateUpdated(uint256 normalizationRate);

    event SystemPaused(address indexed sender);
    event SystemUnpaused(address indexed sender);

    event SystemPrivate(address indexed sender);
    event SystemPublic(address indexed sender);

    event LiquidationsPrivate(address indexed sender);
    event LiquidationsPublic(address indexed sender);

    event LiquidationFeeChanged(address indexed sender, uint32 liquidationFeeD);
    event LiquidationPremiumChanged(address indexed sender, uint32 liquidationPremiumD);
    event MaxDebtPerVaultChanged(address indexed sender, uint256 maxDebtPerVault);
    event MinSingleNftCollateralChanged(address indexed sender, uint256 minSingleNftCollateral);
    event MaxNftsPerVaultChanged(address indexed sender, uint8 maxNftsPerVault);
    event LiquidationThresholdChanged(address indexed sender, address indexed pool, uint32 liquidationThreshold);
    event BorrowThresholdChanged(address indexed sender, address indexed pool, uint32 borrowThreshold);
    event MinWidthChanged(address indexed sender, address indexed pool, uint24 minWidth);

    EIP1967Proxy vaultProxy;
    EIP1967Proxy vaultRegistryProxy;
    BobTokenMock token;
    VaultMock vault;
    VaultRegistry vaultRegistry;
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

        IERC20(weth).approve(address(vault), type(uint256).max);
        IERC20(usdc).approve(address(vault), type(uint256).max);
        IERC20(wbtc).approve(address(vault), type(uint256).max);

        vault.makeLiquidationsPublic();

        skip(1 days);
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

    // addLiquidatorsToAllowlist

    function testAddLiquidatorsToAllowlistSuccess() public {
        address newAddress = getNextUserAddress();
        address[] memory addresses = new address[](1);
        addresses[0] = newAddress;
        vault.addLiquidatorsToAllowlist(addresses);
        address[] memory liquidators = vault.liquidatorsAllowlist();
        assertEq(getLength(liquidators), 1);
        assertEq(newAddress, liquidators[0]);
    }

    // removeDepositorsFromAllowlist

    function testRemoveLiquidatorsFromAllowlistSuccess() public {
        address[] memory addresses = new address[](1);
        addresses[0] = address(this);
        vault.removeLiquidatorsFromAllowlist(addresses);
        address[] memory liquidators = vault.liquidatorsAllowlist();
        assertEq(getLength(liquidators), 0);
    }

    // openVault

    function testOpenVaultSuccess() public {
        uint256 oldLen = vaultRegistry.balanceOf(address(this));
        vault.openVault();
        uint256 currentLen = vaultRegistry.balanceOf(address(this));
        assertEq(oldLen + 1, currentLen);
        vault.openVault();
        uint256 finalLen = vaultRegistry.balanceOf(address(this));
        assertEq(oldLen + 2, finalLen);
    }

    function testOpenVaultWhenForbidden() public {
        vm.expectRevert(Vault.AllowList.selector);

        address newAddress = getNextUserAddress();
        vm.prank(newAddress);

        vault.openVault();
    }

    function testOpenVaultEmit() public {
        vm.expectEmit(true, true, false, false);
        emit VaultOpened(address(this), 1);
        vault.openVault();
    }

    // depositCollateral

    function testDepositCollateralSuccess() public {
        uint256 vaultId = vault.openVault();

        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));

        vault.depositCollateral(vaultId, tokenId);

        uint256[] memory vaultNfts = vault.vaultNftsById(vaultId);
        assertEq(getLength(vaultNfts), 1);
        assertEq(vaultNfts[0], tokenId);
    }

    function testFailDepositCollateralNotApproved() public {
        uint256 vaultId = vault.openVault();

        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));

        vault.depositCollateral(vaultId, tokenId);
        vault.withdrawCollateral(tokenId);
        vault.depositCollateral(vaultId, tokenId); //not approved
    }

    function testFailTryDepositTwice() public {
        uint256 vaultId = vault.openVault();

        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.depositCollateral(vaultId, tokenId);
    }

    function testDepositCollateralWhenForbidden() public {
        address newAddress = getNextUserAddress();
        address[] memory addresses = new address[](1);
        addresses[0] = newAddress;
        vault.addDepositorsToAllowlist(addresses);

        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        positionManager.transferFrom(address(this), newAddress, tokenId);

        vm.startPrank(newAddress);
        uint256 vaultId = vault.openVault();
        vm.stopPrank();

        vault.removeDepositorsFromAllowlist(addresses);

        vm.startPrank(newAddress);
        positionManager.approve(address(vault), tokenId);
        vm.expectRevert(Vault.AllowList.selector);
        vault.depositCollateral(vaultId, tokenId);
    }

    function testDepositCollateralInvalidPool() public {
        uint256 vaultId = vault.openVault();

        vault.setPoolParams(helper.getPool(weth, usdc), ICDP.PoolParams(0.5 gwei, 0, 123));
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**25, address(vault));

        vm.expectRevert(Vault.InvalidPool.selector);
        vault.depositCollateral(vaultId, tokenId);
    }

    function testDepositCollateralNotApprovedToken() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        helper.setTokenPrice(oracle, weth, 0);

        vm.expectRevert(MissingOracle.selector);
        vault.depositCollateral(vaultId, tokenId);
    }

    function testDepositCollateralWhenPositionDoesNotExceedMinCapital() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**10, 10**5, address(vault));

        vm.expectRevert(Vault.CollateralUnderflow.selector);
        vault.depositCollateral(vaultId, tokenId);
    }

    function testDepositCollateralNFTLimitExceeded() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.changeMaxNftsPerVault(1);

        vm.expectRevert(Vault.NFTLimitExceeded.selector);
        vault.depositCollateral(vaultId, tokenId);
    }

    function testDepositCollateralWhenPaused() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));

        vault.pause();

        vm.expectRevert(Vault.Paused.selector);
        vault.depositCollateral(vaultId, tokenId);
    }

    function testDepositCollateralEmit() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));

        vm.expectEmit(true, true, false, true);
        emit CollateralDeposited(address(this), vaultId, tokenId);
        vault.depositCollateral(vaultId, tokenId);
    }

    // closeVault

    function testCloseVaultSuccess() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.closeVault(vaultId, address(this));
        assertEq(vaultRegistry.balanceOf(address(this)), 1);
    }

    function testCloseVaultSuccessWithCollaterals() public {
        uint256 vaultId = vault.openVault();

        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        vault.closeVault(vaultId, address(this));

        assertEq(vaultRegistry.balanceOf(address(this)), 1);
        assertEq(positionManager.ownerOf(tokenId), address(this));
    }

    function testCloseVaultSuccessWithCollateralsToAnotherRecipient() public {
        uint256 vaultId = vault.openVault();

        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        address recipient = getNextUserAddress();
        vault.closeVault(vaultId, recipient);

        assertEq(vaultRegistry.balanceOf(address(this)), 1);
        assertEq(positionManager.ownerOf(tokenId), recipient);
    }

    function testClosedVaultAcceptingCollateral() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.closeVault(vaultId, address(this));

        vault.depositCollateral(vaultId, tokenId);
        assertEq(getLength(vault.vaultNftsById(vaultId)), 1);
    }

    function testCloseWithUnpaidDebt() public {
        uint256 vaultId = vault.openVault();

        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 10);

        vm.expectRevert(Vault.UnpaidDebt.selector);
        vault.closeVault(vaultId, address(this));
    }

    function testCloseVaultWithUnpaidFees() public {
        uint256 vaultId = vault.openVault();

        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1000 * 10**18);

        vm.warp(block.timestamp + YEAR);
        vault.burnDebt(vaultId, 1000 * 10**18);

        vm.expectRevert(Vault.UnpaidDebt.selector);
        vault.closeVault(vaultId, address(this));
    }

    function testCloseVaultWrongOwner() public {
        uint256 vaultId = vault.openVault();
        vm.prank(getNextUserAddress());
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.closeVault(vaultId, address(this));
    }

    function testCloseVaultEmit() public {
        uint256 vaultId = vault.openVault();

        vm.expectEmit(true, true, false, false);
        emit VaultClosed(address(this), vaultId);
        vault.closeVault(vaultId, address(this));
    }

    // mintDebt

    function testMintDebtSuccess() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 10);
        assertEq(token.balanceOf(address(this)), 10);
        vault.checkInvariantOnVault(vaultId);
    }

    function testMintDebtWhenManipulatingPrice() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        helper.makeSwap(weth, usdc, 10**22);
        vm.expectRevert(Vault.TickDeviation.selector);
        vault.mintDebt(vaultId, 10);
    }

    function testMintDebtPaused() public {
        vault.pause();
        vm.expectRevert(Vault.Paused.selector);
        vault.mintDebt(1, 1);
    }

    function testMintDebtWhenNotOwner() public {
        uint256 vaultId = vault.openVault();
        vm.prank(getNextUserAddress());
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.mintDebt(vaultId, 1);
    }

    function testMintDebtWhenPositionUnhealthy() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        vm.expectRevert(Vault.PositionUnhealthy.selector);
        vault.mintDebt(vaultId, type(uint256).max);
    }

    function testMintDebtEmit() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        vm.expectEmit(true, true, false, true);
        emit DebtMinted(address(this), vaultId, 10);

        vault.mintDebt(vaultId, 10);
    }

    function testCorrectFeesWhenMintAfterTimeComes() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        vm.warp(block.timestamp + YEAR);

        vault.mintDebt(vaultId, 1 ether);
        vault.checkInvariantOnVault(vaultId);
        vm.warp(block.timestamp + 1000);
        vault.checkInvariantOnVault(vaultId);
        uint256 debt = vault.getOverallDebt(vaultId);
        assertTrue(debt < 10**14 * 10001); // surely < 0.01%
    }

    // mintDebtFromScratch

    function testMintDebtFromScratchSuccess() public {
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        uint256 vaultId = vault.mintDebtFromScratch(tokenId, 1 ether);

        assertApproxEqual(vault.getOverallDebt(vaultId), 1 ether, 1); // 0.001%
        vault.checkInvariantOnVault(vaultId);
        uint256[] memory nfts = vault.vaultNftsById(vaultId);

        assertTrue(nfts.length == 1);
        assertTrue(nfts[0] == tokenId);
    }

    function testMintDebtFromScratchWhenTooMuchDebtTried() public {
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));

        vm.expectRevert(Vault.PositionUnhealthy.selector);
        vault.mintDebtFromScratch(tokenId, 10**22);
    }

    // deposit collateral via safeTransferFrom

    function testSafeTransferFromSuccess() public {
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        uint256 vaultId = vault.openVault();
        bytes memory data = abi.encode(vaultId);

        positionManager.safeTransferFrom(address(this), address(vault), tokenId, data);

        uint256[] memory nfts = vault.vaultNftsById(vaultId);

        assertTrue(nfts.length == 1);
        assertTrue(nfts[0] == tokenId);
    }

    function testSafeTransferFromWhenCallingDirectly() public {
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        uint256 vaultId = vault.openVault();
        bytes memory data = abi.encode(vaultId);

        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.onERC721Received(address(positionManager), address(this), tokenId, data);
    }

    function testSafeTransferFromEmit() public {
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        uint256 vaultId = vault.openVault();
        bytes memory data = abi.encode(vaultId);

        vm.expectEmit(true, true, false, true);
        emit CollateralDeposited(address(this), vaultId, tokenId);
        positionManager.safeTransferFrom(address(this), address(vault), tokenId, data);
    }

    // depositAndMint via multicall

    function testDepositAndMintSuccess() public {
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        uint256 vaultId = vault.openVault();

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(vault.depositCollateral.selector, vaultId, tokenId);
        data[1] = abi.encodeWithSelector(vault.mintDebt.selector, vaultId, 10**18);

        vault.multicall(data);

        vault.checkInvariantOnVault(vaultId);
        assertApproxEqual(vault.getOverallDebt(vaultId), 10**18, 1);
        uint256[] memory nfts = vault.vaultNftsById(vaultId);

        assertTrue(nfts.length == 1);
        assertTrue(nfts[0] == tokenId);
    }

    function testDepositAndMintSeveralNfts() public {
        uint256 tokenAId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        uint256 tokenBId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        uint256 vaultId = vault.openVault();

        bytes[] memory data = new bytes[](3);
        data[0] = abi.encodeWithSelector(vault.depositCollateral.selector, vaultId, tokenAId);
        data[1] = abi.encodeWithSelector(vault.depositCollateral.selector, vaultId, tokenBId);
        data[2] = abi.encodeWithSelector(vault.mintDebt.selector, vaultId, 10**18);

        vault.multicall(data);

        vault.checkInvariantOnVault(vaultId);
        assertApproxEqual(vault.getOverallDebt(vaultId), 10**18, 1);
        uint256[] memory nfts = vault.vaultNftsById(vaultId);

        assertTrue(nfts.length == 2);
        assertTrue(nfts[0] == tokenAId);
        assertTrue(nfts[1] == tokenBId);
    }

    function testDepositAndMintWhenTooMuchDebtTried() public {
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        uint256 vaultId = vault.openVault();

        vm.expectRevert(Vault.PositionUnhealthy.selector);
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(vault.depositCollateral.selector, vaultId, tokenId);
        data[1] = abi.encodeWithSelector(vault.mintDebt.selector, vaultId, 10**22);

        vault.multicall(data);
    }

    // burnDebt

    function testBurnDebtSuccess() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 10);
        vault.checkInvariantOnVault(vaultId);
        vault.burnDebt(vaultId, 10);
        vault.checkInvariantOnVault(vaultId);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function testBurnMoreThanDebtSuccess() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 10);
        vault.burnDebt(vaultId, 1000);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function testFailBurnMoreThanBalance() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1000);
        vm.warp(block.timestamp + YEAR);
        vault.burnDebt(vaultId, 1003);
    }

    function testFailBurnAfterTransferPartOfBalance() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1000);

        address receiver = getNextUserAddress();
        token.transfer(receiver, 500);

        vault.burnDebt(vaultId, 600);
    }

    function testPartialBurnSuccess() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 300 * 10**18);
        vault.checkInvariantOnVault(vaultId);
        vm.warp(block.timestamp + YEAR);

        vault.checkInvariantOnVault(vaultId);
        vault.burnDebt(vaultId, 150 * 10**18);
        vault.checkInvariantOnVault(vaultId);
        assertEq(token.balanceOf(address(this)), 150 * 10**18);
        assertApproxEqual(token.balanceOf(address(treasury)), 15 * 10**17, 100); // ~1.5$
        assertApproxEqual(vault.getOverallDebt(vaultId), 153 * 10**18, 1);
    }

    function testPartialFeesBurnSuccess() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 300 ether);
        vm.warp(block.timestamp + YEAR);

        deal(address(token), address(this), 303 ether);
        vault.checkInvariantOnVault(vaultId);
        vault.burnDebt(vaultId, 302 ether);
        vault.checkInvariantOnVault(vaultId);

        assertEq(token.balanceOf(address(this)), 1 ether);
        assertApproxEqual(token.balanceOf(address(treasury)), 3 ether, 10); // ~3$
        assertApproxEqual(vault.getOverallDebt(vaultId), 1 ether, 1);
    }

    function testBurnDebtSuccessWithFees() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 300 ether);
        vault.checkInvariantOnVault(vaultId);
        vm.warp(block.timestamp + YEAR);
        vault.checkInvariantOnVault(vaultId);
        uint256 overallDebt = vault.getOverallDebt(vaultId);
        assertApproxEqual(overallDebt, 303 ether, 1); // +1%
        // setting balance manually assuming that we'll swap tokens on DEX
        deal(address(token), address(this), 303 ether);
        vault.checkInvariantOnVault(vaultId);
        vault.burnDebt(vaultId, overallDebt);
        vault.checkInvariantOnVault(vaultId);
        assertTrue(token.balanceOf(address(this)) < 10**10); // dust
        assertApproxEqual(token.balanceOf(address(treasury)), 3 ether, 1);
    }

    function testBurnDebtWhenPaused() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 300 * 10**18);
        vault.checkInvariantOnVault(vaultId);
        vm.warp(block.timestamp + YEAR);
        vault.checkInvariantOnVault(vaultId);

        deal(address(token), address(this), 303 * 10**18);
        vault.pause();
        assertApproxEqual(vault.getOverallDebt(vaultId), 303 ether, 1);
        vault.checkInvariantOnVault(vaultId);
        vault.burnDebt(vaultId, 302 * 10**18);
        vault.checkInvariantOnVault(vaultId);
        assertEq(token.balanceOf(address(this)), 1 ether);
        assertApproxEqual(token.balanceOf(address(treasury)), 3 ether, 4);
        assertApproxEqual(vault.getOverallDebt(vaultId), 1 ether, 1);
    }

    function testBurnDebtWhenNotOwner() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 10);
        vault.checkInvariantOnVault(vaultId);

        address user = getNextUserAddress();
        vm.startPrank(user);
        deal(address(token), user, 10);
        token.approve(address(vault), 10);
        vault.checkInvariantOnVault(vaultId);
        vault.burnDebt(vaultId, 1);
        vault.checkInvariantOnVault(vaultId);
        assertEq(token.balanceOf(address(this)), 10);
        assertEq(token.balanceOf(user), 9);
        vm.stopPrank();
    }

    function testBurnDebtEmit() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        vault.mintDebt(vaultId, 10);

        vm.expectEmit(true, true, false, true);
        emit DebtBurned(address(this), vaultId, 10);

        vault.burnDebt(vaultId, 10);
    }

    // withdrawCollateral

    function testWithdrawCollateralSuccess() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.withdrawCollateral(tokenId);
        assertEq(getLength(vault.vaultNftsById(vaultId)), 0);
        assertEq(positionManager.ownerOf(tokenId), address(this));
    }

    function testWithdrawCollateralWhenPaused() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.pause();
        vault.withdrawCollateral(tokenId);
        assertEq(getLength(vault.vaultNftsById(vaultId)), 0);
        assertEq(positionManager.ownerOf(tokenId), address(this));
    }

    function testWithdrawCollateralWhenManipulatingPriceAndEmptyingVault() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        helper.makeSwap(weth, usdc, 10**22);
        vault.withdrawCollateral(tokenId);
        (uint256 total, uint256 liquidationLimit, uint256 borrowLimit) = vault.calculateVaultCollateral(vaultId);
        assertEq(total, 0);
        assertEq(liquidationLimit, 0);
        assertEq(borrowLimit, 0);
    }

    function testWithdrawCollateralWhenManipulatingPriceAndVaultNonEmpty() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenAId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        uint256 tokenBId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenAId);
        vault.depositCollateral(vaultId, tokenBId);
        helper.makeSwap(weth, usdc, 10**22);
        vm.expectRevert(Vault.TickDeviation.selector);
        vault.withdrawCollateral(tokenAId);
    }

    function testWithdrawCollateralWhenNotOwner() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        vm.prank(getNextUserAddress());
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.withdrawCollateral(tokenId);
    }

    function testWithdrawCollateralWhenPositionGoingUnhealthy() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1);
        vm.expectRevert(Vault.PositionUnhealthy.selector);
        vault.withdrawCollateral(tokenId);
    }

    function testWithdrawCollateralEmit() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vm.expectEmit(true, true, false, true);
        emit CollateralWithdrew(address(this), vaultId, tokenId);
        vault.withdrawCollateral(tokenId);
    }

    // decreaseLiquidity

    function testDecreaseLiquiditySuccess() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        INonfungiblePositionLoader.PositionInfo memory info = helper.positions(tokenId);
        (uint256 total, uint256 liquidationLimit, uint256 borrowLimit) = vault.calculateVaultCollateral(vaultId);
        (, uint256 price, , ) = nftOracle.price(tokenId);
        vault.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: info.liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
        (, uint256 newPrice, , ) = nftOracle.price(tokenId);
        (uint256 newTotal, uint256 newLiquidationLimit, uint256 newBorrowLimit) = vault.calculateVaultCollateral(
            vaultId
        );
        info = helper.positions(tokenId);
        assertEq(info.liquidity, 0);
        assertTrue(total != newTotal);
        assertTrue(liquidationLimit != newLiquidationLimit);
        assertTrue(borrowLimit != newBorrowLimit);
        assertTrue(price != newPrice);
    }

    function testDecreaseLiquidityWhenPaused() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.pause();
        INonfungiblePositionLoader.PositionInfo memory info = helper.positions(tokenId);
        vault.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: info.liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
        info = helper.positions(tokenId);
        assertEq(info.liquidity, 0);
    }

    function testDecreaseLiquidityWhenNotOwner() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        INonfungiblePositionLoader.PositionInfo memory info = helper.positions(tokenId);
        vm.prank(getNextUserAddress());
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: info.liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
    }

    function testDecreaseLiquidityWhenPositionBecomingUnhealthy() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        INonfungiblePositionLoader.PositionInfo memory info = helper.positions(tokenId);
        vault.mintDebt(vaultId, 1190 * 10**18);
        helper.setTokenPrice(oracle, weth, 800 << 96);
        vm.expectRevert(Vault.PositionUnhealthy.selector);
        vault.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: info.liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
    }

    // collect

    function testCollectSuccess() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        (uint256 total, uint256 liquidationLimit, uint256 borrowLimit) = vault.calculateVaultCollateral(vaultId);
        INonfungiblePositionLoader.PositionInfo memory info = helper.positions(tokenId);
        vault.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: info.liquidity / 2,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
        vault.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        (uint256 newTotal, uint256 newLiquidationLimit, uint256 newBorrowLimit) = vault.calculateVaultCollateral(
            vaultId
        );
        assertApproxEqual(total / 2, newTotal, 10);
        assertApproxEqual(liquidationLimit / 2, newLiquidationLimit, 10);
        assertApproxEqual(borrowLimit / 2, newBorrowLimit, 10);
    }

    function testCollectWhenPaused() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.pause();
        (uint256 total, uint256 liquidationLimit, uint256 borrowLimit) = vault.calculateVaultCollateral(vaultId);
        INonfungiblePositionLoader.PositionInfo memory info = helper.positions(tokenId);
        vault.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: info.liquidity / 2,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
        vault.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        (uint256 newTotal, uint256 newLiquidationLimit, uint256 newBorrowLimit) = vault.calculateVaultCollateral(
            vaultId
        );
        assertApproxEqual(total / 2, newTotal, 10);
        assertApproxEqual(liquidationLimit / 2, newLiquidationLimit, 10);
        assertApproxEqual(borrowLimit / 2, newBorrowLimit, 10);
    }

    function testCollectWhenManipulatingPrice() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        INonfungiblePositionLoader.PositionInfo memory info = helper.positions(tokenId);
        vault.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: info.liquidity / 2,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
        helper.makeSwap(weth, usdc, 10**22);
        vm.expectRevert(Vault.TickDeviation.selector);
        vault.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }

    function testCollectWhenCollateralUnderflow() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        INonfungiblePositionLoader.PositionInfo memory info = helper.positions(tokenId);
        vault.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: info.liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
        vm.expectRevert(Vault.CollateralUnderflow.selector);
        vault.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }

    function testCollectWhenNotOwner() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        INonfungiblePositionLoader.PositionInfo memory info = helper.positions(tokenId);
        vm.prank(getNextUserAddress());
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }

    function testCollectWhenPositionGoingUnhealthy() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1);
        INonfungiblePositionLoader.PositionInfo memory info = helper.positions(tokenId);
        vault.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: info.liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
        vm.expectRevert(Vault.PositionUnhealthy.selector);
        vault.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }

    // decreaseAndCollect via multicall

    function testDecreaseAndCollectSuccess() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        (uint256 total, uint256 liquidationLimit, uint256 borrowLimit) = vault.calculateVaultCollateral(vaultId);
        INonfungiblePositionLoader.PositionInfo memory info = helper.positions(tokenId);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(
            vault.decreaseLiquidity.selector,
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: info.liquidity / 2,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
        data[1] = abi.encodeWithSelector(
            vault.collect.selector,
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        vault.multicall(data);
        (uint256 newTotal, uint256 newLiquidationLimit, uint256 newBorrowLimit) = vault.calculateVaultCollateral(
            vaultId
        );
        assertApproxEqual(total / 2, newTotal, 10);
        assertApproxEqual(liquidationLimit / 2, newLiquidationLimit, 10);
        assertApproxEqual(borrowLimit / 2, newBorrowLimit, 10);
    }

    // collectAndIncrease

    function testCollectAndIncreaseAmountSuccess() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        (uint256 total, uint256 liquidationLimit, uint256 borrowLimit) = vault.calculateVaultCollateral(vaultId);
        INonfungiblePositionLoader.PositionInfo memory info = helper.positions(tokenId);
        vault.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: info.liquidity / 2,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
        deal(weth, address(this), 10000 ether);
        deal(usdc, address(this), 10000 ether);
        deal(wbtc, address(this), 10000 ether);
        vault.collectAndIncreaseAmount(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            }),
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: 10**9 / 2,
                amount1Desired: 10**18 / 2,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
        (uint256 newTotal, uint256 newLiquidationLimit, uint256 newBorrowLimit) = vault.calculateVaultCollateral(
            vaultId
        );
        assertApproxEqual(total, newTotal, 10);
        assertApproxEqual(liquidationLimit, newLiquidationLimit, 10);
        assertApproxEqual(borrowLimit, newBorrowLimit, 10);
    }

    function testCollectAndIncreaseAmountWhenPaused() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.pause();
        (uint256 total, uint256 liquidationLimit, uint256 borrowLimit) = vault.calculateVaultCollateral(vaultId);
        INonfungiblePositionLoader.PositionInfo memory info = helper.positions(tokenId);
        vault.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: info.liquidity / 2,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
        deal(weth, address(this), 10000 ether);
        deal(usdc, address(this), 10000 ether);
        deal(wbtc, address(this), 10000 ether);
        vault.collectAndIncreaseAmount(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            }),
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: 10**9 / 2,
                amount1Desired: 10**18 / 2,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
        (uint256 newTotal, uint256 newLiquidationLimit, uint256 newBorrowLimit) = vault.calculateVaultCollateral(
            vaultId
        );
        assertApproxEqual(total, newTotal, 10);
        assertApproxEqual(liquidationLimit, newLiquidationLimit, 10);
        assertApproxEqual(borrowLimit, newBorrowLimit, 10);
    }

    function testCollectAndIncreaseAmountWhenManipulatingPrice() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        INonfungiblePositionLoader.PositionInfo memory info = helper.positions(tokenId);
        vault.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: info.liquidity / 2,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
        helper.makeSwap(weth, usdc, 10**22);
        deal(weth, address(this), 10000 ether);
        deal(usdc, address(this), 10000 ether);
        deal(wbtc, address(this), 10000 ether);
        vm.expectRevert(Vault.TickDeviation.selector);
        vault.collectAndIncreaseAmount(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            }),
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: 10**9 / 2,
                amount1Desired: 10**18 / 2,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
    }

    function testCollectAndIncreaseAmountWhenCollateralUnderflow() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        INonfungiblePositionLoader.PositionInfo memory info = helper.positions(tokenId);
        vault.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: info.liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
        deal(weth, address(this), 10000 ether);
        deal(usdc, address(this), 10000 ether);
        deal(wbtc, address(this), 10000 ether);
        vm.expectRevert(Vault.CollateralUnderflow.selector);
        vault.collectAndIncreaseAmount(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            }),
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: 10**2,
                amount1Desired: 10**10,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
    }

    function testCollectAndIncreaseAmountWhenNotOwner() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        INonfungiblePositionLoader.PositionInfo memory info = helper.positions(tokenId);
        vault.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: info.liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
        deal(weth, address(this), 10000 ether);
        deal(usdc, address(this), 10000 ether);
        deal(wbtc, address(this), 10000 ether);
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vm.prank(getNextUserAddress());
        vault.collectAndIncreaseAmount(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            }),
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: 10**2,
                amount1Desired: 10**10,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
    }

    function testCollectAndIncreaseAmountWhenPositionGoingUnhealthy() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1000 ether);
        INonfungiblePositionLoader.PositionInfo memory info = helper.positions(tokenId);
        vault.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: info.liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
        deal(weth, address(this), 10000 ether);
        deal(usdc, address(this), 10000 ether);
        deal(wbtc, address(this), 10000 ether);
        vm.expectRevert(Vault.PositionUnhealthy.selector);
        vault.collectAndIncreaseAmount(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            }),
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: 10**2,
                amount1Desired: 10**10,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
    }

    // health factor

    function testHealthFactorSuccess() public {
        uint256 vaultId = vault.openVault();
        (uint256 total, uint256 liquidationLimit, uint256 borrowLimit) = vault.calculateVaultCollateral(vaultId);
        assertEq(total, 0);
        assertEq(liquidationLimit, 0);
        assertEq(borrowLimit, 0);
    }

    function testHealthFactorAfterDeposit() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        uint256 lowCapitalBound = 10**18 * 1100;
        uint256 upCapitalBound = 10**18 * 1300; // health apparently ~1200USD est: (1000(eth price) + 1000) * 0.6 = 1200
        vault.depositCollateral(vaultId, tokenId);
        (uint256 total, uint256 liquidationLimit, uint256 borrowLimit) = vault.calculateVaultCollateral(vaultId);
        assertApproxEqual(2000 ether, total, 50);
        assertApproxEqual(1400 ether, liquidationLimit, 50);
        assertApproxEqual(1200 ether, borrowLimit, 50);
    }

    function testHealthFactorAfterDepositWithdraw() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.withdrawCollateral(tokenId);
        (uint256 total, uint256 liquidationLimit, uint256 borrowLimit) = vault.calculateVaultCollateral(vaultId);
        assertEq(total, 0);
        assertEq(liquidationLimit, 0);
        assertEq(borrowLimit, 0);
    }

    function testHealthFactorMultipleDeposits() public {
        uint256 vaultId = vault.openVault();
        uint256 nftA = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        uint256 nftB = helper.openPosition(wbtc, weth, 10**8, 10**18 * 20, address(vault));
        uint256[3] memory total;
        uint256[3] memory liquidationLimit;
        uint256[3] memory borrowLimit;
        vault.depositCollateral(vaultId, nftA);
        (total[0], liquidationLimit[0], borrowLimit[0]) = vault.calculateVaultCollateral(vaultId);
        vault.depositCollateral(vaultId, nftB);
        (total[1], liquidationLimit[1], borrowLimit[1]) = vault.calculateVaultCollateral(vaultId);
        vault.withdrawCollateral(nftB);
        (total[2], liquidationLimit[2], borrowLimit[2]) = vault.calculateVaultCollateral(vaultId);

        assertEq(total[0], total[2]);
        assertEq(liquidationLimit[0], liquidationLimit[2]);
        assertEq(borrowLimit[0], borrowLimit[2]);
        assertLt(total[0], total[1]);
        assertLt(liquidationLimit[0], liquidationLimit[1]);
        assertLt(borrowLimit[0], borrowLimit[1]);
    }

    function testHealthFactorAfterPriceChange() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        uint256[3] memory total;
        uint256[3] memory liquidationLimit;
        uint256[3] memory borrowLimit;
        (total[0], liquidationLimit[0], borrowLimit[0]) = vault.calculateVaultCollateral(vaultId);
        helper.setTokenPrice(oracle, weth, 800 << 96);
        (total[1], liquidationLimit[1], borrowLimit[1]) = vault.calculateVaultCollateral(vaultId);
        helper.setTokenPrice(oracle, weth, 1400 << 96);
        (total[2], liquidationLimit[2], borrowLimit[2]) = vault.calculateVaultCollateral(vaultId);

        assertGt(total[0], total[1]);
        assertLt(total[1], total[2]);
        assertGt(liquidationLimit[0], liquidationLimit[1]);
        assertLt(liquidationLimit[1], liquidationLimit[2]);
        assertGt(borrowLimit[0], borrowLimit[1]);
        assertLt(borrowLimit[1], borrowLimit[2]);
    }

    function testHealthFactorAfterPoolChange() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        uint256[2] memory total;
        uint256[2] memory liquidationLimit;
        uint256[2] memory borrowLimit;
        (total[0], liquidationLimit[0], borrowLimit[0]) = vault.calculateVaultCollateral(vaultId);
        helper.makeSwap(weth, usdc, 10**18);
        (total[1], liquidationLimit[1], borrowLimit[1]) = vault.calculateVaultCollateral(vaultId);
        assertLt(total[0], total[1]);
        assertLt(liquidationLimit[0], liquidationLimit[1]);
        assertLt(borrowLimit[0], borrowLimit[1]);
    }

    function testHealthFactorAfterThresholdChange() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        address pool = helper.getPool(weth, usdc);

        vault.setPoolParams(pool, ICDP.PoolParams(0.5 gwei, 0.1 gwei, 123));
        (uint256 total, uint256 liquidationLimit, uint256 borrowLimit) = vault.calculateVaultCollateral(vaultId);
        assertApproxEqual(2000 ether, total, 50);
        assertApproxEqual(1000 ether, liquidationLimit, 50);
        assertApproxEqual(200 ether, borrowLimit, 50);

        vault.setPoolParams(pool, ICDP.PoolParams(0, 0, 0));
        (total, liquidationLimit, borrowLimit) = vault.calculateVaultCollateral(vaultId);
        assertApproxEqual(2000 ether, total, 50);
        assertEq(liquidationLimit, 0);
        assertEq(borrowLimit, 0);
    }

    function testHealthFactorFromRandomAddress() public {
        uint256 vaultId = vault.openVault();
        vm.prank(getNextUserAddress());
        (uint256 total, uint256 liquidationLimit, uint256 borrowLimit) = vault.calculateVaultCollateral(vaultId);
        assertEq(total, 0);
        assertEq(liquidationLimit, 0);
        assertEq(borrowLimit, 0);
    }

    function testHealthFactorNonExistingVault() public {
        uint256 nextId = vaultRegistry.totalSupply() + 123;
        (uint256 total, uint256 liquidationLimit, uint256 borrowLimit) = vault.calculateVaultCollateral(nextId);
        assertEq(total, 0);
        assertEq(liquidationLimit, 0);
        assertEq(borrowLimit, 0);
    }

    // liquidate

    function testLiquidateSuccess() public {
        uint256 vaultId = vault.openVault();
        // overall ~2000$ -> HF: ~1200$
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1000 * 10**18);
        vault.checkInvariantOnVault(vaultId);
        // eth 1000 -> 800
        helper.setTokenPrice(oracle, weth, 700 << 96);

        address randomAddress = getNextUserAddress();
        token.transfer(randomAddress, vault.getOverallDebt(vaultId));

        vm.warp(block.timestamp + 5 * YEAR);
        vault.checkInvariantOnVault(vaultId);
        (uint256 total, uint256 liquidationLimit, ) = vault.calculateVaultCollateral(vaultId);
        {
            uint256 debt = vault.getOverallDebt(vaultId);

            assertTrue(liquidationLimit < debt);
        }
        address liquidator = getNextUserAddress();

        deal(address(token), liquidator, 2000 * 10**18, true);
        uint256 oldLiquidatorBalance = token.balanceOf(liquidator);
        uint256 debtToBeRepaid = vault.getOverallDebt(vaultId);

        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);
        vault.liquidate(vaultId);
        vault.checkInvariantOnVault(vaultId);
        vm.stopPrank();

        uint256 liquidatorSpent = oldLiquidatorBalance - token.balanceOf(liquidator);

        uint256 targetTreasuryBalance = 50 ether + (total * uint256(vault.protocolParams().liquidationFeeD)) / 10**9;
        uint256 treasuryGot = token.balanceOf(address(treasury));

        assertApproxEqual(targetTreasuryBalance, treasuryGot, 150);
        assertEq(positionManager.ownerOf(tokenId), liquidator);

        uint256 lowerBoundRemaning = 100 * 10**18;
        uint256 gotBack = vault.vaultOwed(vaultId);

        assertTrue(lowerBoundRemaning <= gotBack);
        assertApproxEqual(
            gotBack + debtToBeRepaid + FullMath.mulDiv(total, vault.protocolParams().liquidationFeeD, 10**9),
            liquidatorSpent,
            1
        );

        assertEq(vault.getOverallDebt(vaultId), 0);
    }

    function testFailLiquidateWithProfitWhenPricePlummets() public {
        uint256 vaultId = vault.openVault();
        // overall ~2000$ -> HF: ~1200$
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1000 * 10**18);
        // eth 1000 -> 1
        helper.setTokenPrice(oracle, weth, 1 << 96);

        address liquidator = getNextUserAddress();
        (, uint256 liquidationLimit, ) = vault.calculateVaultCollateral(vaultId);
        uint256 nftPrice = (liquidationLimit / 6) * 10;
        deal(address(token), liquidator, nftPrice, true);

        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);
        vault.liquidate(vaultId);
    }

    function testLiquidateSuccessWhenLiquidationsPrivate() public {
        uint256 vaultId = vault.openVault();
        // overall ~2000$ -> HF: ~1200$
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1000 * 10**18);
        vault.checkInvariantOnVault(vaultId);
        // eth 1000 -> 800
        helper.setTokenPrice(oracle, weth, 700 << 96);

        address randomAddress = getNextUserAddress();
        token.transfer(randomAddress, vault.getOverallDebt(vaultId));

        vm.warp(block.timestamp + 5 * YEAR);
        (uint256 total, uint256 liquidationLimit, ) = vault.calculateVaultCollateral(vaultId);
        {
            uint256 debt = vault.getOverallDebt(vaultId);

            assertTrue(liquidationLimit < debt);
        }
        address liquidator = getNextUserAddress();
        address[] memory liquidatorsToAllowance = new address[](1);
        liquidatorsToAllowance[0] = liquidator;

        vault.addLiquidatorsToAllowlist(liquidatorsToAllowance);

        deal(address(token), liquidator, 2000 * 10**18, true);
        uint256 oldLiquidatorBalance = token.balanceOf(liquidator);
        uint256 debtToBeRepaid = vault.getOverallDebt(vaultId);

        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);
        vault.liquidate(vaultId);
        vault.checkInvariantOnVault(vaultId);
        vm.stopPrank();

        assertEq(vault.getOverallDebt(vaultId), 0);
    }

    function testLiquidateWhenNotInAllowlist() public {
        uint256 vaultId = vault.openVault();
        vault.makeLiquidationsPrivate();
        vm.expectRevert(Vault.LiquidatorsAllowList.selector);
        vault.liquidate(vaultId);
    }

    function testLiquidateWhenPricePlummets() public {
        uint256 vaultId = vault.openVault();
        // overall ~2000$ -> HF: ~1200$
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1000 * 10**18);
        // eth 1000 -> 1
        helper.setTokenPrice(oracle, weth, 1 << 96);

        address liquidator = getNextUserAddress();
        deal(address(token), liquidator, 1100 * 10**18, true);

        uint256 oldBalanceTreasury = token.balanceOf(address(treasury));
        uint256 oldBalanceOwner = token.balanceOf(address(this));

        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);
        vault.checkInvariantOnVault(vaultId);
        vault.liquidate(vaultId);
        vault.checkInvariantOnVault(vaultId);
        vm.stopPrank();

        uint256 newBalanceTreasury = token.balanceOf(address(treasury));
        uint256 newBalanceOwner = token.balanceOf(address(this));

        assertEq(oldBalanceTreasury, newBalanceTreasury);
        assertEq(oldBalanceOwner, newBalanceOwner);
    }

    function testLiquidateWhenVaultOwnerReceiveNothingButDaoReceiveSomething() public {
        uint256 vaultId = vault.openVault();
        // overall ~2000$ -> HF: ~1200$
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1000 * 10**18);
        helper.setTokenPrice(oracle, weth, 600 << 96);

        address liquidator = getNextUserAddress();
        deal(address(token), liquidator, 20000 * 10**18, true);

        uint256 oldBalanceTreasury = token.balanceOf(address(treasury));
        uint256 oldBalanceOwner = token.balanceOf(address(this));

        vm.warp(block.timestamp + YEAR * 60);

        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);
        vault.checkInvariantOnVault(vaultId);
        vault.liquidate(vaultId);
        vault.checkInvariantOnVault(vaultId);
        vm.stopPrank();

        uint256 newBalanceTreasury = token.balanceOf(address(treasury));
        uint256 newBalanceOwner = token.balanceOf(address(this));

        assertTrue(oldBalanceTreasury != newBalanceTreasury);
        assertEq(oldBalanceOwner, newBalanceOwner);
    }

    function testFailLiquidateWithSmallAmount() public {
        uint256 vaultId = vault.openVault();
        // overall ~2000$ -> HF: ~1200$
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1100 * 10**18);
        // eth 1000 -> 800
        helper.setTokenPrice(oracle, weth, 800 << 96);

        address liquidator = getNextUserAddress();
        deal(address(token), liquidator, 2000 * 10**18, true);

        vm.startPrank(liquidator);
        token.approve(address(vault), vault.getOverallDebt(vaultId)); //too small for liquidating
        vault.liquidate(vaultId);
    }

    function testLiquidateWhenPositionHealthy() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));

        (, uint256 liquidationLimit, ) = vault.calculateVaultCollateral(vaultId);
        uint256 debt = vault.getOverallDebt(vaultId);

        assertTrue(debt <= liquidationLimit);

        vault.depositCollateral(vaultId, tokenId);
        vm.expectRevert(Vault.PositionHealthy.selector);
        vault.liquidate(vaultId);
    }

    function testLiquidateEmit() public {
        uint256 vaultId = vault.openVault();
        // overall ~2000$ -> HF: ~1200$
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1100 * 10**18);
        // eth 1000 -> 800
        helper.setTokenPrice(oracle, weth, 800 << 96);

        vm.warp(block.timestamp + 5 * YEAR);
        (, uint256 liquidationLimit, ) = vault.calculateVaultCollateral(vaultId);
        uint256 debt = vault.getOverallDebt(vaultId);

        assertTrue(liquidationLimit < debt);

        address liquidator = getNextUserAddress();

        deal(address(token), liquidator, 2000 * 10**18, true);

        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);

        vm.expectEmit(true, true, false, false);
        emit VaultLiquidated(liquidator, vaultId);
        vault.liquidate(vaultId);
        vm.stopPrank();
    }

    // withdrawOwed

    function testWithdrawOwed() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1000 * 10**18);
        helper.setTokenPrice(oracle, weth, 700 << 96);

        address liquidator = getNextUserAddress();
        deal(address(token), liquidator, 2000 * 10**18, true);

        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);
        vault.liquidate(vaultId);
        vm.stopPrank();

        uint256 owed = vault.vaultOwed(vaultId);

        assertGt(owed, 100 * 10**18);

        address user = getNextUserAddress();
        vm.prank(user);
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.withdrawOwed(vaultId, user, 100);

        assertEq(token.balanceOf(user), 0);
        assertEq(vault.vaultOwed(vaultId), owed);
        vault.withdrawOwed(vaultId, user, 100);
        assertEq(token.balanceOf(user), 100);
        assertEq(vault.vaultOwed(vaultId), owed - 100);
        vault.withdrawOwed(vaultId, user, type(uint256).max);
        assertEq(token.balanceOf(user), owed);
        assertEq(vault.vaultOwed(vaultId), 0);
    }

    // makePublic

    function testMakePublicSuccess() public {
        vault.makePublic();
        assertEq(vault.isPublic(), true);
    }

    function testMakePublicWhenNotAdmin() public {
        vm.prank(getNextUserAddress());
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.makePublic();
    }

    function testMakePublicEmit() public {
        vm.expectEmit(true, false, false, false);
        emit SystemPublic(address(this));
        vault.makePublic();
    }

    // makePrivate

    function testMakePrivateSuccess() public {
        vault.makePrivate();
        assertEq(vault.isPublic(), false);
    }

    function testMakePrivateWhenNotAdmin() public {
        vm.prank(getNextUserAddress());
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.makePrivate();
    }

    function testMakePrivateEmit() public {
        vm.expectEmit(true, false, false, false);
        emit SystemPrivate(address(this));
        vault.makePrivate();
    }

    // makeLiquidationsPublic

    function testMakeLiquidationsPublicSuccess() public {
        vault.makeLiquidationsPublic();
        assertEq(vault.isLiquidatingPublic(), true);
    }

    function testMakeLiquidationsPublicWhenNotAdmin() public {
        vm.prank(getNextUserAddress());
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.makeLiquidationsPublic();
    }

    function testMakeLiquidationsPublicEmit() public {
        vm.expectEmit(true, false, false, false);
        emit LiquidationsPublic(address(this));
        vault.makeLiquidationsPublic();
    }

    // makeLiquidationsPrivate

    function testMakeLiquidationsPrivateSuccess() public {
        vault.makeLiquidationsPrivate();
        assertEq(vault.isLiquidatingPublic(), false);
    }

    function testMakeLiquidationsPrivateWhenNotAdmin() public {
        vm.prank(getNextUserAddress());
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.makeLiquidationsPrivate();
    }

    function testMakeLiquidationsPrivateEmit() public {
        vm.expectEmit(true, false, false, false);
        emit LiquidationsPrivate(address(this));
        vault.makeLiquidationsPrivate();
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
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.pause();
    }

    function testPauseEmit() public {
        vm.expectEmit(true, false, false, false);
        emit SystemPaused(address(this));
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
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.unpause();
    }

    function testUnpauseWhenNotAdmin() public {
        vm.prank(getNextUserAddress());
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.unpause();
    }

    function testUnpauseEmit() public {
        vm.expectEmit(true, false, false, false);
        emit SystemUnpaused(address(this));
        vault.unpause();
    }

    // vaultNftsById

    function testVaultNftsByIdSuccess() public {
        uint256 vaultId = vault.openVault();
        assertEq(getLength(vault.vaultNftsById(vaultId)), 0);
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        uint256[] memory nfts = vault.vaultNftsById(vaultId);
        assertEq(getLength(nfts), 1);
        assertEq(nfts[0], tokenId);
    }

    // getOverallDebt

    function testOverallDebtSuccess() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 300 * 10**18);
        uint256 overallDebt = vault.getOverallDebt(vaultId);
        assertEq(overallDebt, 300 * 10**18);
    }

    function testOverallDebtSuccessWithFees() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 300 * 10**18);
        vm.warp(block.timestamp + YEAR); // 1 YEAR
        uint256 overallDebt = vault.getOverallDebt(vaultId);
        assertApproxEqual(overallDebt, 303 * 10**18, 1); // +1%
    }

    // updateStabilisationFeeRate

    function testUpdateStabilisationFeeSuccess() public {
        vault.updateStabilisationFeeRate((2 * 10**16) / YEAR);
        assertEq(vault.stabilisationFeeRateD(), (2 * 10**16) / YEAR);
    }

    function testUpdateStabilisationFeeSuccessWithCalculations() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 300 ether);
        vm.warp(block.timestamp + YEAR);
        uint256 overallDebt = vault.getOverallDebt(vaultId);
        assertApproxEqual(overallDebt, 303 ether, 10); // +1%
        vault.updateStabilisationFeeRate(10**17 / YEAR);
        vm.warp(block.timestamp + YEAR);
        overallDebt = vault.getOverallDebt(vaultId);
        assertApproxEqual(overallDebt, 333 ether, 10); // +1% per first year and +10% per second year
    }

    function testUpdateStabilisationFeeWhenNotAdmin() public {
        vm.prank(getNextUserAddress());
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.updateStabilisationFeeRate(10**16 / YEAR);
    }

    function testUpdateStabilisationFeeWithInvalidValue() public {
        vm.expectRevert(Vault.InvalidValue.selector);
        vault.updateStabilisationFeeRate(10**20 / YEAR);
    }

    function testUpdateStabilisationFeeEmit() public {
        vm.expectEmit(true, false, false, true);
        emit StabilisationFeeUpdated(address(this), (2 * 10**16) / YEAR);
        vault.updateStabilisationFeeRate((2 * 10**16) / YEAR);
    }

    // protocolParams

    function testDefaultProtocolParams() public {
        ICDP.ProtocolParams memory params = vault.protocolParams();
        assertEq(params.maxDebtPerVault, type(uint256).max);
        assertEq(params.minSingleNftCollateral, 100000000000000000);
        assertEq(params.liquidationPremiumD, 30000000);
        assertEq(params.liquidationFeeD, 30000000);
        assertEq(params.maxNftsPerVault, 12);
    }

    function testChangedProtocolParams() public {
        vault.changeLiquidationFee(3 * 10**7);
        vault.changeLiquidationPremium(3 * 10**7);
        vault.changeMaxDebtPerVault(10**24);
        vault.changeMinSingleNftCollateral(10**18);
        vault.changeMaxNftsPerVault(30);
        ICDP.ProtocolParams memory newParams = vault.protocolParams();
        assertEq(newParams.liquidationFeeD, 3 * 10**7);
        assertEq(newParams.liquidationPremiumD, 3 * 10**7);
        assertEq(newParams.maxDebtPerVault, 10**24);
        assertEq(newParams.minSingleNftCollateral, 10**18);
        assertEq(newParams.maxNftsPerVault, 30);
    }

    // changeLiquidationFee

    function testLiquidationFeeSuccess() public {
        vault.changeLiquidationFee(10**8);
        ICDP.ProtocolParams memory newParams = vault.protocolParams();
        assertEq(newParams.liquidationFeeD, 10**8);
    }

    function testLiquidationFeeTooLarge() public {
        vm.expectRevert(Vault.InvalidValue.selector);
        vault.changeLiquidationFee(2 * 10**9);
    }

    function testLiquidationFeeAccessControl() public {
        address newAddress = getNextUserAddress();
        vm.startPrank(newAddress);
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.changeLiquidationFee(11 * 10**7);
    }

    function testLiquidationFeeEventEmitted() public {
        vm.expectEmit(true, false, false, true);
        emit LiquidationFeeChanged(address(this), 10**6);
        vault.changeLiquidationFee(10**6);
    }

    // changeLiquidationPremium

    function testLiquidationPremiumSuccess() public {
        vault.changeLiquidationPremium(10**8);
        ICDP.ProtocolParams memory newParams = vault.protocolParams();
        assertEq(newParams.liquidationPremiumD, 10**8);
    }

    function testLiquidationPremiumTooLarge() public {
        vm.expectRevert(Vault.InvalidValue.selector);
        vault.changeLiquidationPremium(2 * 10**9);
    }

    function testLiquidationPremiumAccessControl() public {
        address newAddress = getNextUserAddress();
        vm.startPrank(newAddress);
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.changeLiquidationPremium(11 * 10**7);
    }

    function testLiquidationPremiumEventEmitted() public {
        vm.expectEmit(true, false, false, true);
        emit LiquidationPremiumChanged(address(this), 10**6);
        vault.changeLiquidationPremium(10**6);
    }

    // changeMaxDebtPerVault

    function testMaxDebtPerVaultSuccess() public {
        vault.changeMaxDebtPerVault(10**25);
        ICDP.ProtocolParams memory newParams = vault.protocolParams();
        assertEq(newParams.maxDebtPerVault, 10**25);
    }

    function testMaxDebtPerVaultAccessControl() public {
        address newAddress = getNextUserAddress();
        vm.startPrank(newAddress);
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.changeMaxDebtPerVault(1);
    }

    function testMaxDebtPerVaultAnyValue() public {
        vault.changeMaxDebtPerVault(0);
        vault.changeMaxDebtPerVault(type(uint256).max);
        vault.changeMaxDebtPerVault(2**100);
        vault.changeMaxDebtPerVault(1);
        ICDP.ProtocolParams memory newParams = vault.protocolParams();
        assertEq(newParams.maxDebtPerVault, 1);
    }

    function testMaxDebtPerVaultEventEmitted() public {
        vm.expectEmit(true, false, false, true);
        emit MaxDebtPerVaultChanged(address(this), 10**10);
        vault.changeMaxDebtPerVault(10**10);
    }

    // changeSingleNftCollateral

    function testChangeMinSingleNftCollateralSuccess() public {
        vault.changeMinSingleNftCollateral(10**18);
        ICDP.ProtocolParams memory newParams = vault.protocolParams();
        assertEq(newParams.minSingleNftCollateral, 10**18);
    }

    function testChangeMinSingleNftCollateralAccessControl() public {
        address newAddress = getNextUserAddress();
        vm.startPrank(newAddress);
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.changeMinSingleNftCollateral(10**18);
    }

    function testChangeMinSingleNftCollateralEmitted() public {
        vm.expectEmit(true, false, false, true);
        emit MinSingleNftCollateralChanged(address(this), 10**20);
        vault.changeMinSingleNftCollateral(10**20);
    }

    // changeMaxNftsPerVault

    function testChangeMaxNftsPerVault() public {
        vault.changeMaxNftsPerVault(20);
        ICDP.ProtocolParams memory newParams = vault.protocolParams();
        assertEq(newParams.maxNftsPerVault, 20);
    }

    function testChangeMaxNftsPerVaultAccessControl() public {
        address newAddress = getNextUserAddress();
        vm.startPrank(newAddress);
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.changeMaxNftsPerVault(20);
    }

    function testChangeMaxNftsPerVaultEmitted() public {
        vm.expectEmit(true, false, false, true);
        emit MaxNftsPerVaultChanged(address(this), 20);
        vault.changeMaxNftsPerVault(20);
    }

    // setPoolParams

    function testSetPoolParamsSuccess() public {
        address pool = helper.getPool(dai, usdc);
        vault.setPoolParams(pool, ICDP.PoolParams(0.5 gwei, 0.4 gwei, 123));
        assertEq(vault.poolParams(pool).liquidationThreshold, 0.5 gwei);
        assertEq(vault.poolParams(pool).borrowThreshold, 0.4 gwei);
        assertEq(vault.poolParams(pool).minWidth, 123);
    }

    function testSetPoolParamsZeroThresholdIsOkay() public {
        address pool = helper.getPool(dai, usdc);
        vault.setPoolParams(pool, ICDP.PoolParams(0.5 gwei, 0 gwei, 123));
        assertEq(vault.poolParams(pool).liquidationThreshold, 0.5 gwei);
        assertEq(vault.poolParams(pool).borrowThreshold, 0 gwei);
        assertEq(vault.poolParams(pool).minWidth, 123);
    }

    function testSetPoolParamsErrors() public {
        address pool = helper.getPool(dai, usdc);
        vm.expectRevert(Vault.InvalidValue.selector);
        vault.setPoolParams(pool, ICDP.PoolParams(1.5 gwei, 0.4 gwei, 123));
        vm.expectRevert(Vault.InvalidValue.selector);
        vault.setPoolParams(pool, ICDP.PoolParams(0.5 gwei, 1.4 gwei, 123));
        vm.expectRevert(Vault.InvalidValue.selector);
        vault.setPoolParams(pool, ICDP.PoolParams(0.5 gwei, 0.6 gwei, 123));
        vm.expectRevert(VaultAccessControl.AddressZero.selector);
        vault.setPoolParams(address(0), ICDP.PoolParams(0.5 gwei, 0.4 gwei, 123));
    }

    function testSetPoolParamsAccessControl() public {
        address pool = helper.getPool(weth, usdc);
        address newAddress = getNextUserAddress();
        vm.startPrank(newAddress);
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.setPoolParams(pool, ICDP.PoolParams(0.5 gwei, 0.4 gwei, 123));
    }

    function testSetPoolParamsEmitted() public {
        address pool = helper.getPool(weth, usdc);

        vm.expectEmit(true, true, false, true);
        emit LiquidationThresholdChanged(address(this), pool, 0.5 gwei);
        vm.expectEmit(true, true, false, true);
        emit BorrowThresholdChanged(address(this), pool, 0.4 gwei);
        vm.expectEmit(true, true, false, true);
        emit MinWidthChanged(address(this), pool, 123);
        vault.setPoolParams(pool, ICDP.PoolParams(0.5 gwei, 0.4 gwei, 123));
    }
}
