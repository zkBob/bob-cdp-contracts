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

abstract contract AbstractVaultTest is SetupContract, AbstractForkTest, AbstractLateSetup {
    error MissingOracle();
    event VaultOpened(address indexed sender, uint256 vaultId);
    event VaultLiquidated(address indexed sender, uint256 vaultId);
    event VaultClosed(address indexed sender, uint256 vaultId);

    event CollateralDeposited(address indexed sender, uint256 vaultId, uint256 nft);
    event CollateralWithdrew(address indexed sender, uint256 vaultId, uint256 nft);

    event DebtMinted(address indexed sender, uint256 vaultId, uint256 amount);
    event DebtBurned(address indexed sender, uint256 vaultId, uint256 amount);

    event StabilisationFeeUpdated(address indexed origin, address indexed sender, uint256 stabilisationFee);
    event OracleUpdated(address indexed origin, address indexed sender, address oracleAddress);

    event SystemPaused(address indexed origin, address indexed sender);
    event SystemUnpaused(address indexed origin, address indexed sender);

    event SystemPrivate(address indexed origin, address indexed sender);
    event SystemPublic(address indexed origin, address indexed sender);

    event LiquidationsPrivate(address indexed origin, address indexed sender);
    event LiquidationsPublic(address indexed origin, address indexed sender);

    event LiquidationFeeChanged(address indexed origin, address indexed sender, uint32 liquidationFeeD);
    event LiquidationPremiumChanged(address indexed origin, address indexed sender, uint32 liquidationPremiumD);
    event MaxDebtPerVaultChanged(address indexed origin, address indexed sender, uint256 maxDebtPerVault);
    event MinSingleNftCollateralChanged(address indexed origin, address indexed sender, uint256 minSingleNftCollateral);
    event MaxNftsPerVaultChanged(address indexed origin, address indexed sender, uint8 maxNftsPerVault);
    event WhitelistedPoolSet(address indexed origin, address indexed sender, address pool);
    event WhitelistedPoolRevoked(address indexed origin, address indexed sender, address pool);
    event TokenLimitSet(address indexed origin, address indexed sender, address token, uint256 stagedLimit);
    event LiquidationThresholdSet(
        address indexed origin,
        address indexed sender,
        address pool,
        uint256 liquidationThresholdD
    );

    EIP1967Proxy vaultProxy;
    EIP1967Proxy vaultRegistryProxy;
    BobTokenMock token;
    Vault vault;
    VaultRegistry vaultRegistry;
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

        vaultRegistry = new VaultRegistry("BOB Vault Token", "BVT", "");
        vaultRegistryProxy = new EIP1967Proxy(address(this), address(vaultRegistry), "");
        vaultRegistry = VaultRegistry(address(vaultRegistryProxy));

        vault = new Vault(
            INonfungiblePositionManager(PositionManager),
            INFTOracle(address(nftOracle)),
            treasury,
            address(token),
            address(token),
            address(vaultRegistry)
        );

        bytes memory initData = abi.encodeWithSelector(
            Vault.initialize.selector,
            address(this),
            10**7,
            type(uint256).max
        );
        vaultProxy = new EIP1967Proxy(address(this), address(vault), initData);
        vault = Vault(address(vaultProxy));

        vaultRegistry.setMinter(address(vault), true);

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
        vm.expectEmit(true, false, false, true);
        emit VaultOpened(address(this), vaultRegistry.totalSupply() + 1);
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

        vault.revokeWhitelistedPool(helper.getPool(weth, usdc));
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

    function testDepositCollateralWhenPositionExceedsMinCapitalButEstimationNotSuccess() public {
        address pool = helper.getPool(weth, usdc);
        vault.setLiquidationThreshold(pool, 10**7); // 1%
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**15, 10**6, address(vault));

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

        vm.expectEmit(true, false, false, true);
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

        vm.expectEmit(true, false, false, true);
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

        vm.expectEmit(true, false, false, true);
        emit DebtMinted(address(this), vaultId, 10);

        vault.mintDebt(vaultId, 10);
    }

    function testCorrectFeesWhenMintAfterTimeComes() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        vm.warp(block.timestamp + YEAR);

        vault.mintDebt(vaultId, 10**18);
        vm.warp(block.timestamp + 1000);

        uint256 debt = vault.getOverallDebt(vaultId);
        assertTrue(debt < 10**14 * 10001); // surely < 0.01%
    }

    // mintDebtFromScratch

    function testMintDebtFromScratchSuccess() public {
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        uint256 vaultId = vault.mintDebtFromScratch(tokenId, 10**18);

        assertTrue(vault.vaultDebt(vaultId) == 10**18);
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

        vm.expectEmit(true, false, false, true);
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

        assertTrue(vault.vaultDebt(vaultId) == 10**18);
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

        assertTrue(vault.vaultDebt(vaultId) == 10**18);
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
        vault.burnDebt(vaultId, 10);
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
        vm.warp(block.timestamp + YEAR);

        vault.burnDebt(vaultId, 150 * 10**18);
        assertEq(token.balanceOf(address(this)), 150 * 10**18);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(vault.stabilisationFeeVaultSnapshot(vaultId), 3 * 10**18);
        assertEq(vault.vaultDebt(vaultId), 150 * 10**18);
    }

    function testPartialFeesBurnSuccess() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
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
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
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
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 300 * 10**18);
        vm.warp(block.timestamp + YEAR);

        deal(address(token), address(this), 303 * 10**18);
        vault.pause();
        vault.burnDebt(vaultId, 302 * 10**18);

        assertEq(token.balanceOf(address(this)), 1 * 10**18);
        assertEq(token.balanceOf(treasury), 2 * 10**18);
        assertEq(vault.stabilisationFeeVaultSnapshot(vaultId), 10**18);
        assertEq(vault.vaultDebt(vaultId), 0);
    }

    function testBurnDebtWhenNotOwner() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 10);

        address user = getNextUserAddress();
        vm.startPrank(user);
        deal(address(token), user, 10);
        token.approve(address(vault), 10);
        vault.burnDebt(vaultId, 1);
        assertEq(token.balanceOf(address(this)), 10);
        assertEq(token.balanceOf(user), 9);
        vm.stopPrank();
    }

    function testBurnDebtEmit() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        vault.mintDebt(vaultId, 10);

        vm.expectEmit(true, false, false, true);
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
        (uint256 overallCollateral, uint256 adjustedCollateral) = vault.calculateVaultCollateral(vaultId);
        assertEq(overallCollateral, 0);
        assertEq(adjustedCollateral, 0);
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
        vm.expectEmit(true, false, false, true);
        emit CollateralWithdrew(address(this), vaultId, tokenId);
        vault.withdrawCollateral(tokenId);
    }

    // decreaseLiquidity

    function testDecreaseLiquiditySuccess() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        INonfungiblePositionLoader.PositionInfo memory info = helper.positions(tokenId);
        (uint256 overallCollateral, uint256 adjustedCollateral) = vault.calculateVaultCollateral(vaultId);
        (, uint256 price, ) = nftOracle.price(tokenId);
        vault.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: info.liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
        (, uint256 newPrice, ) = nftOracle.price(tokenId);
        (uint256 newOverallCollateral, uint256 newAdjustedCollateral) = vault.calculateVaultCollateral(vaultId);
        info = helper.positions(tokenId);
        assertEq(info.liquidity, 0);
        assertTrue(overallCollateral != newOverallCollateral);
        assertTrue(adjustedCollateral != newAdjustedCollateral);
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
        (uint256 adjustedCollateral, ) = vault.calculateVaultCollateral(vaultId);
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
        (uint256 overallCollateral, uint256 adjustedCollateral) = vault.calculateVaultCollateral(vaultId);
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
        (uint256 newOverallCollateral, uint256 newAdjustedCollateral) = vault.calculateVaultCollateral(vaultId);
        assertApproxEqual(overallCollateral / 2, newOverallCollateral, 10);
        assertApproxEqual(adjustedCollateral / 2, newAdjustedCollateral, 10);
    }

    function testCollectWhenPaused() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.pause();
        (uint256 overallCollateral, uint256 adjustedCollateral) = vault.calculateVaultCollateral(vaultId);
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
        (uint256 newOverallCollateral, uint256 newAdjustedCollateral) = vault.calculateVaultCollateral(vaultId);
        assertApproxEqual(overallCollateral / 2, newOverallCollateral, 10);
        assertApproxEqual(adjustedCollateral / 2, newAdjustedCollateral, 10);
    }

    function testCollectWhenManipulatingPrice() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        (uint256 overallCollateral, uint256 adjustedCollateral) = vault.calculateVaultCollateral(vaultId);
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
        (uint256 overallCollateral, uint256 adjustedCollateral) = vault.calculateVaultCollateral(vaultId);
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
        (uint256 newOverallCollateral, uint256 newAdjustedCollateral) = vault.calculateVaultCollateral(vaultId);
        assertApproxEqual(overallCollateral / 2, newOverallCollateral, 10);
        assertApproxEqual(adjustedCollateral / 2, newAdjustedCollateral, 10);
    }

    // collectAndIncrease

    function testCollectAndIncreaseAmountSuccess() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        (uint256 overallCollateral, uint256 adjustedCollateral) = vault.calculateVaultCollateral(vaultId);
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
        (uint256 newOverallCollateral, uint256 newAdjustedCollateral) = vault.calculateVaultCollateral(vaultId);
        assertApproxEqual(overallCollateral, newOverallCollateral, 10);
        assertApproxEqual(adjustedCollateral, newAdjustedCollateral, 10);
    }

    function testCollectAndIncreaseAmountWhenPaused() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.pause();
        (uint256 overallCollateral, uint256 adjustedCollateral) = vault.calculateVaultCollateral(vaultId);
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
        (uint256 newOverallCollateral, uint256 newAdjustedCollateral) = vault.calculateVaultCollateral(vaultId);
        assertApproxEqual(overallCollateral, newOverallCollateral, 10);
        assertApproxEqual(adjustedCollateral, newAdjustedCollateral, 10);
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
        (uint256 overallCollateral, uint256 adjustedCollateral) = vault.calculateVaultCollateral(vaultId);
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
        (uint256 overallCollateral, uint256 adjustedCollateral) = vault.calculateVaultCollateral(vaultId);
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
        (uint256 overallCollateral, uint256 adjustedCollateral) = vault.calculateVaultCollateral(vaultId);
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
        (, uint256 health) = vault.calculateVaultCollateral(vaultId);
        assertEq(health, 0);
    }

    function testHealthFactorAfterDeposit() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        uint256 lowCapitalBound = 10**18 * 1100;
        uint256 upCapitalBound = 10**18 * 1300; // health apparently ~1200USD est: (1000(eth price) + 1000) * 0.6 = 1200
        vault.depositCollateral(vaultId, tokenId);
        (, uint256 health) = vault.calculateVaultCollateral(vaultId);
        assertTrue(health >= lowCapitalBound && health <= upCapitalBound);
    }

    function testHealthFactorAfterDepositWithdraw() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.withdrawCollateral(tokenId);
        (, uint256 health) = vault.calculateVaultCollateral(vaultId);
        assertEq(health, 0);
    }

    function testHealthFactorMultipleDeposits() public {
        uint256 vaultId = vault.openVault();
        uint256 nftA = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        uint256 nftB = helper.openPosition(wbtc, weth, 10**8, 10**18 * 20, address(vault));
        vault.depositCollateral(vaultId, nftA);
        (, uint256 healthOneAsset) = vault.calculateVaultCollateral(vaultId);
        vault.depositCollateral(vaultId, nftB);
        (, uint256 healthTwoAssets) = vault.calculateVaultCollateral(vaultId);
        vault.withdrawCollateral(nftB);
        (, uint256 healthOneAssetFinal) = vault.calculateVaultCollateral(vaultId);

        assertEq(healthOneAsset, healthOneAssetFinal);
        assertTrue(healthOneAsset < healthTwoAssets);
    }

    function testHealthFactorAfterPriceChange() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        (, uint256 healthPreAction) = vault.calculateVaultCollateral(vaultId);
        helper.setTokenPrice(oracle, weth, 800 << 96);
        (, uint256 healthLowPrice) = vault.calculateVaultCollateral(vaultId);
        helper.setTokenPrice(oracle, weth, 1400 << 96);
        (, uint256 healthHighPrice) = vault.calculateVaultCollateral(vaultId);

        assertTrue(healthLowPrice < healthPreAction);
        assertTrue(healthPreAction < healthHighPrice);
    }

    function testHealthFactorAfterPoolChange() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);

        (, uint256 healthPreAction) = vault.calculateVaultCollateral(vaultId);
        helper.makeSwap(weth, usdc, 10**18);
        (, uint256 healthPostAction) = vault.calculateVaultCollateral(vaultId);
        assertTrue(healthPreAction != healthPostAction);
        assertApproxEqual(healthPreAction, healthPostAction, 1);
    }

    function testHealthFactorAfterThresholdChange() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        address pool = helper.getPool(weth, usdc);

        vault.setLiquidationThreshold(pool, 1e8);
        uint256 lowCapitalBound = 10**18 * 150;
        uint256 upCapitalBound = 10**18 * 250; // health apparently ~200USD
        (, uint256 health) = vault.calculateVaultCollateral(vaultId);
        assertTrue(health >= lowCapitalBound && health <= upCapitalBound);

        vault.revokeWhitelistedPool(pool);
        (, uint256 healthNoAssets) = vault.calculateVaultCollateral(vaultId);
        assertEq(healthNoAssets, 0);
    }

    function testHealthFactorFromRandomAddress() public {
        uint256 vaultId = vault.openVault();
        vm.prank(getNextUserAddress());
        (, uint256 health) = vault.calculateVaultCollateral(vaultId);
        assertEq(health, 0);
    }

    function testHealthFactorNonExistingVault() public {
        uint256 nextId = vaultRegistry.totalSupply() + 123;
        (, uint256 health) = vault.calculateVaultCollateral(nextId);
        assertEq(health, 0);
    }

    // liquidate

    function testLiquidateSuccess() public {
        uint256 vaultId = vault.openVault();
        // overall ~2000$ -> HF: ~1200$
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, tokenId);
        vault.mintDebt(vaultId, 1000 * 10**18);
        // eth 1000 -> 800
        helper.setTokenPrice(oracle, weth, 700 << 96);

        address randomAddress = getNextUserAddress();
        token.transfer(randomAddress, vault.vaultDebt(vaultId));

        vm.warp(block.timestamp + 5 * YEAR);
        (uint256 vaultAmount, uint256 health) = vault.calculateVaultCollateral(vaultId);
        {
            uint256 debt = vault.vaultDebt(vaultId) + vault.stabilisationFeeVaultSnapshot(vaultId);

            assertTrue(health < debt);
        }
        address liquidator = getNextUserAddress();

        deal(address(token), liquidator, 2000 * 10**18, true);
        uint256 oldLiquidatorBalance = token.balanceOf(liquidator);
        uint256 debtToBeRepaid = vault.vaultDebt(vaultId);

        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);
        vault.liquidate(vaultId);
        vm.stopPrank();

        uint256 liquidatorSpent = oldLiquidatorBalance - token.balanceOf(liquidator);

        uint256 targetTreasuryBalance = 50 ether +
            (vaultAmount * uint256(vault.protocolParams().liquidationFeeD)) /
            10**9;
        uint256 treasuryGot = token.balanceOf(address(treasury));

        assertApproxEqual(targetTreasuryBalance, treasuryGot, 150);
        assertEq(positionManager.ownerOf(tokenId), liquidator);

        uint256 lowerBoundRemaning = 100 * 10**18;
        uint256 gotBack = vault.vaultOwed(vaultId);

        assertTrue(lowerBoundRemaning <= gotBack);
        assertEq(gotBack + debtToBeRepaid + treasuryGot, liquidatorSpent);

        assertEq(vault.vaultDebt(vaultId), 0);
        assertEq(vault.stabilisationFeeVaultSnapshot(vaultId), 0);
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
        (, uint256 health) = vault.calculateVaultCollateral(vaultId);
        uint256 nftPrice = (health / 6) * 10;
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
        // eth 1000 -> 800
        helper.setTokenPrice(oracle, weth, 700 << 96);

        address randomAddress = getNextUserAddress();
        token.transfer(randomAddress, vault.vaultDebt(vaultId));

        vm.warp(block.timestamp + 5 * YEAR);
        (uint256 vaultAmount, uint256 health) = vault.calculateVaultCollateral(vaultId);
        {
            uint256 debt = vault.vaultDebt(vaultId) + vault.stabilisationFeeVaultSnapshot(vaultId);

            assertTrue(health < debt);
        }
        address liquidator = getNextUserAddress();
        address[] memory liquidatorsToAllowance = new address[](1);
        liquidatorsToAllowance[0] = liquidator;

        vault.addLiquidatorsToAllowlist(liquidatorsToAllowance);

        deal(address(token), liquidator, 2000 * 10**18, true);
        uint256 oldLiquidatorBalance = token.balanceOf(liquidator);
        uint256 debtToBeRepaid = vault.vaultDebt(vaultId);

        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);
        vault.liquidate(vaultId);
        vm.stopPrank();

        assertEq(vault.vaultDebt(vaultId), 0);
        assertEq(vault.stabilisationFeeVaultSnapshot(vaultId), 0);
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

        uint256 oldBalanceTreasury = token.balanceOf(treasury);
        uint256 oldBalanceOwner = token.balanceOf(address(this));

        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);
        vault.liquidate(vaultId);
        vm.stopPrank();

        uint256 newBalanceTreasury = token.balanceOf(treasury);
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

        uint256 oldBalanceTreasury = token.balanceOf(treasury);
        uint256 oldBalanceOwner = token.balanceOf(address(this));

        vm.warp(block.timestamp + YEAR * 60);

        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);
        vault.liquidate(vaultId);
        vm.stopPrank();

        uint256 newBalanceTreasury = token.balanceOf(treasury);
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
        token.approve(address(vault), vault.vaultDebt(vaultId)); //too small for liquidating
        vault.liquidate(vaultId);
    }

    function testLiquidateWhenPositionHealthy() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));

        (, uint256 health) = vault.calculateVaultCollateral(vaultId);
        uint256 debt = vault.vaultDebt(vaultId) + vault.stabilisationFeeVaultSnapshot(vaultId);

        assertTrue(debt <= health);

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
        (, uint256 health) = vault.calculateVaultCollateral(vaultId);
        uint256 debt = vault.vaultDebt(vaultId) + vault.stabilisationFeeVaultSnapshot(vaultId);

        assertTrue(health < debt);

        address liquidator = getNextUserAddress();

        deal(address(token), liquidator, 2000 * 10**18, true);

        vm.startPrank(liquidator);
        token.approve(address(vault), type(uint256).max);

        vm.expectEmit(true, false, false, true);
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
        vm.expectEmit(false, true, false, false);
        emit SystemPublic(getNextUserAddress(), address(this));
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
        vm.expectEmit(false, true, false, false);
        emit SystemPrivate(getNextUserAddress(), address(this));
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
        vm.expectEmit(false, true, false, false);
        emit LiquidationsPublic(getNextUserAddress(), address(this));
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
        vm.expectEmit(false, true, false, false);
        emit LiquidationsPrivate(getNextUserAddress(), address(this));
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
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.unpause();
    }

    function testUnpauseWhenNotAdmin() public {
        vm.prank(getNextUserAddress());
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.unpause();
    }

    function testUnpauseEmit() public {
        vm.expectEmit(false, true, false, false);
        emit SystemUnpaused(getNextUserAddress(), address(this));
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
        assertEq(overallDebt, 303 * 10**18); // +1%
    }

    // updateStabilisationFeeRate

    function testUpdateStabilisationFeeSuccess() public {
        vault.updateStabilisationFeeRate(2 * 10**7);
        assertEq(vault.stabilisationFeeRateD(), 2 * 10**7);
    }

    function testUpdateStabilisationFeeSuccessWithCalculations() public {
        uint256 vaultId = vault.openVault();
        uint256 tokenId = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
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
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
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

    // isPoolWhitelisted + setWhitelistedPool + revokeWhitelistedPool

    function testSetGetWhitelistedPoolSuccess() public {
        address pool = helper.getPool(weth, usdc);
        vault.setWhitelistedPool(pool);
        assertTrue(vault.isPoolWhitelisted(pool));
    }

    function testPoolNotWhitelisted() public {
        address pool = helper.getPool(dai, usdc);
        assertTrue(!vault.isPoolWhitelisted(pool));
    }

    function testRevokedPool() public {
        address pool = helper.getPool(weth, usdc);
        vault.setWhitelistedPool(pool);
        vault.revokeWhitelistedPool(pool);
        assertTrue(!vault.isPoolWhitelisted(pool));
    }

    // whitelistedPool

    function testGetWhitelistedPoolSuccess() public {
        address pool = helper.getPool(dai, usdc);
        vault.setWhitelistedPool(pool);
        assertTrue(pool == vault.whitelistedPool(3));
    }

    function testSeveralPoolsOkay() public {
        address poolA = helper.getPool(weth, dai);
        address poolB = helper.getPool(dai, usdc);
        vault.setWhitelistedPool(poolA);
        vault.setWhitelistedPool(poolB);

        address pool0 = vault.whitelistedPool(3);
        address pool1 = vault.whitelistedPool(4);

        assertTrue(pool0 != pool1);
        assertTrue(pool0 == poolA || pool0 == poolB);
        assertTrue(pool1 == poolA || pool1 == poolB);
    }

    function testFailMissingIndex() public {
        vault.whitelistedPool(10);
    }

    // Access control of all public methods

    function testAccessControlsAllAccountsMethods() public {
        address pool = helper.getPool(weth, usdc);
        vault.setWhitelistedPool(pool);

        address newAddress = getNextUserAddress();
        vm.startPrank(newAddress);

        vault.protocolParams();
        vault.isPoolWhitelisted(pool);
        vault.liquidationThresholdD(usdc);
        vault.whitelistedPool(0);
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
        vm.expectEmit(false, true, false, true);
        emit LiquidationFeeChanged(getNextUserAddress(), address(this), 10**6);
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
        vm.expectEmit(false, true, false, true);
        emit LiquidationPremiumChanged(getNextUserAddress(), address(this), 10**6);
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
        vm.expectEmit(false, true, false, true);
        emit MaxDebtPerVaultChanged(getNextUserAddress(), address(this), 10**10);
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
        vm.expectEmit(false, true, false, true);
        emit MinSingleNftCollateralChanged(getNextUserAddress(), address(this), 10**20);
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
        vm.expectEmit(false, true, false, true);
        emit MaxNftsPerVaultChanged(getNextUserAddress(), address(this), 20);
        vault.changeMaxNftsPerVault(20);
    }

    // setWhitelistedPool

    function testSetWhitelistedPoolZeroAddress() public {
        vm.expectRevert(VaultAccessControl.AddressZero.selector);
        vault.setWhitelistedPool(address(0));
    }

    function testSetWhitelistedPoolAccessControl() public {
        address newAddress = getNextUserAddress();
        vm.startPrank(newAddress);
        address pool = helper.getPool(weth, usdc);
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.setWhitelistedPool(pool);
    }

    function testSetSeveralPoolsOkay() public {
        helper.setPools(ICDP(vault));
    }

    function testSetWhitelistedPoolEmitted() public {
        address pool = helper.getPool(weth, usdc);
        vm.expectEmit(false, true, false, true);
        emit WhitelistedPoolSet(getNextUserAddress(), address(this), pool);
        vault.setWhitelistedPool(pool);
    }

    // revokeWhitelistedPool

    function testRevokePoolAccessControl() public {
        address pool = helper.getPool(weth, usdc);
        vault.setWhitelistedPool(pool);
        address newAddress = getNextUserAddress();
        vm.startPrank(newAddress);
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.revokeWhitelistedPool(pool);
    }

    function testTryRevokeUnstagedPoolIsOkay() public {
        address pool = helper.getPool(weth, usdc);
        vault.revokeWhitelistedPool(pool);
    }

    function testRevokePoolEmitted() public {
        address pool = helper.getPool(weth, usdc);
        vault.setWhitelistedPool(pool);

        vm.expectEmit(false, true, false, true);
        emit WhitelistedPoolRevoked(getNextUserAddress(), address(this), pool);
        vault.revokeWhitelistedPool(pool);
    }

    // setLiquidationThreshold

    function testSetThresholdSuccess() public {
        address pool = helper.getPool(dai, usdc);
        vault.setWhitelistedPool(pool);
        assertEq(vault.liquidationThresholdD(pool), 0);
        vault.setLiquidationThreshold(pool, 5 * 10**8);
        assertEq(vault.liquidationThresholdD(pool), 5 * 10**8);
    }

    function testSetZeroThresholdIsOkay() public {
        address pool = helper.getPool(weth, usdc);
        vault.setWhitelistedPool(pool);
        vault.setLiquidationThreshold(pool, 0);
        assertEq(vault.liquidationThresholdD(pool), 0);
    }

    function testSetNewThreshold() public {
        address pool = helper.getPool(weth, usdc);
        vault.setWhitelistedPool(pool);
        vault.setLiquidationThreshold(pool, 5 * 10**8);
        assertEq(vault.liquidationThresholdD(pool), 5 * 10**8);
        vault.setLiquidationThreshold(pool, 3 * 10**8);
        assertEq(vault.liquidationThresholdD(pool), 3 * 10**8);
    }

    function testSetThresholdNotWhitelisted() public {
        address pool = helper.getPool(dai, usdc);
        vm.expectRevert(Vault.InvalidPool.selector);
        vault.setLiquidationThreshold(pool, 5 * 10**8);
    }

    function testSetThresholdWhitelistedThenRevoked() public {
        address pool = helper.getPool(weth, usdc);
        vault.setWhitelistedPool(pool);
        vault.setLiquidationThreshold(pool, 5 * 10**8);
        vault.revokeWhitelistedPool(pool);
        assertEq(vault.liquidationThresholdD(pool), 0);
        vm.expectRevert(Vault.InvalidPool.selector);
        vault.setLiquidationThreshold(pool, 3 * 10**8);
    }

    function testSetTooLargeThreshold() public {
        address pool = helper.getPool(weth, usdc);
        vault.setWhitelistedPool(pool);
        vm.expectRevert(Vault.InvalidValue.selector);
        vault.setLiquidationThreshold(pool, 2 * 10**9);
    }

    function testSetThresholdZeroAddress() public {
        vm.expectRevert(VaultAccessControl.AddressZero.selector);
        vault.setLiquidationThreshold(address(0), 10**5);
    }

    function testSetThresholdAccessControl() public {
        address pool = helper.getPool(weth, usdc);
        address newAddress = getNextUserAddress();
        vm.startPrank(newAddress);
        vm.expectRevert(VaultAccessControl.Forbidden.selector);
        vault.setLiquidationThreshold(pool, 10**5);
    }

    function testSetThresholdEmitted() public {
        address pool = helper.getPool(weth, usdc);
        vault.setWhitelistedPool(pool);

        vm.expectEmit(false, true, false, true);
        emit LiquidationThresholdSet(getNextUserAddress(), address(this), pool, 10**6);
        vault.setLiquidationThreshold(pool, 10**6);
    }
}
