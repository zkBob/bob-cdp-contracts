// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "../lib/forge-std/src/Test.sol";
import "./ConfigContract.sol";
import "./SetupContract.sol";
import "./utils/Utilities.sol";
import "src/interfaces/IProtocolGovernance.sol";

contract ProtocolGovernanceTest is Test, SetupContract, Utilities {
    event LiquidationFeeChanged(address indexed origin, address indexed sender, uint256 liquidationFeeD);
    event LiquidationPremiumChanged(address indexed origin, address indexed sender, uint256 liquidationPremiumD);
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

    ProtocolGovernance protocolGovernance;

    function setUp() public {
        protocolGovernance = new ProtocolGovernance(address(this), type(uint256).max);
    }

    // protocolParams

    function testDefaultProtocolParams() public {
        IProtocolGovernance.ProtocolParams memory params = protocolGovernance.protocolParams();
        assertEq(params.liquidationFeeD, 0);
        assertEq(params.liquidationPremiumD, 0);
        assertEq(params.maxDebtPerVault, type(uint256).max);
        assertEq(params.minSingleNftCollateral, 0);
    }

    function testChangedProtocolParams() public {
        protocolGovernance.changeLiquidationFee(3 * 10**7);
        protocolGovernance.changeLiquidationPremium(3 * 10**7);
        protocolGovernance.changeMaxDebtPerVault(10**24);
        protocolGovernance.changeMinSingleNftCollateral(10**18);
        IProtocolGovernance.ProtocolParams memory newParams = protocolGovernance.protocolParams();
        assertEq(newParams.liquidationFeeD, 3 * 10**7);
        assertEq(newParams.liquidationPremiumD, 3 * 10**7);
        assertEq(newParams.maxDebtPerVault, 10**24);
        assertEq(newParams.minSingleNftCollateral, 10**18);
    }

    // isPoolWhitelisted + setWhitelistedPool + revokeWhitelistedPool

    function testSetGetWhitelistedPoolSuccess() public {
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        protocolGovernance.setWhitelistedPool(pool);
        assertTrue(protocolGovernance.isPoolWhitelisted(pool));
    }

    function testPoolNotWhitelisted() public {
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        assertTrue(!protocolGovernance.isPoolWhitelisted(pool));
    }

    function testRevokedPool() public {
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        protocolGovernance.setWhitelistedPool(pool);
        protocolGovernance.revokeWhitelistedPool(pool);
        assertTrue(!protocolGovernance.isPoolWhitelisted(pool));
    }

    // whitelistedPool

    function testGetWhitelistedPoolSuccess() public {
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        protocolGovernance.setWhitelistedPool(pool);
        assertTrue(pool == protocolGovernance.whitelistedPool(0));
    }

    function testSeveralPoolsOkay() public {
        address poolA = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        address poolB = IUniswapV3Factory(UniV3Factory).getPool(wbtc, usdc, 3000);
        protocolGovernance.setWhitelistedPool(poolA);
        protocolGovernance.setWhitelistedPool(poolB);

        address pool0 = protocolGovernance.whitelistedPool(0);
        address pool1 = protocolGovernance.whitelistedPool(1);

        assertTrue(pool0 != pool1);
        assertTrue(pool0 == poolA || pool0 == poolB);
        assertTrue(pool1 == poolA || pool1 == poolB);
    }

    function testFailMissingIndex() public {
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        protocolGovernance.setWhitelistedPool(pool);
        protocolGovernance.whitelistedPool(1);
    }

    // supportsInterface

    function testSupportsInterfaceId() public {
        assertTrue(protocolGovernance.supportsInterface(type(IProtocolGovernance).interfaceId));
    }

    function testNotSupportsInterfaceId() public {
        bytes4 randomString = 0xabc00012;
        assertTrue(!protocolGovernance.supportsInterface(randomString));
    }

    // Access control of all public methods

    function testAccessControlsAllAccountsMethods() public {
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        protocolGovernance.setWhitelistedPool(pool);

        address newAddress = getNextUserAddress();
        vm.startPrank(newAddress);

        protocolGovernance.protocolParams();
        protocolGovernance.isPoolWhitelisted(pool);
        protocolGovernance.liquidationThresholdD(usdc);
        protocolGovernance.whitelistedPool(0);
    }

    // changeLiquidationFee

    function testLiquidationFeeSuccess() public {
        protocolGovernance.changeLiquidationFee(10**8);
        IProtocolGovernance.ProtocolParams memory newParams = protocolGovernance.protocolParams();
        assertEq(newParams.liquidationFeeD, 10**8);
    }

    function testLiquidationFeeTooLarge() public {
        vm.expectRevert(ProtocolGovernance.InvalidValue.selector);
        protocolGovernance.changeLiquidationFee(2 * 10**9);
    }

    function testLiquidationFeeAccessControl() public {
        address newAddress = getNextUserAddress();
        vm.startPrank(newAddress);
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        protocolGovernance.changeLiquidationFee(11 * 10**7);
    }

    function testLiquidationFeeEventEmitted() public {
        vm.expectEmit(false, true, false, true);
        emit LiquidationFeeChanged(getNextUserAddress(), address(this), 10**6);
        protocolGovernance.changeLiquidationFee(10**6);
    }

    // changeLiquidationPremium

    function testLiquidationPremiumSuccess() public {
        protocolGovernance.changeLiquidationPremium(10**8);
        IProtocolGovernance.ProtocolParams memory newParams = protocolGovernance.protocolParams();
        assertEq(newParams.liquidationPremiumD, 10**8);
    }

    function testLiquidationPremiumTooLarge() public {
        vm.expectRevert(ProtocolGovernance.InvalidValue.selector);
        protocolGovernance.changeLiquidationPremium(2 * 10**9);
    }

    function testLiquidationPremiumAccessControl() public {
        address newAddress = getNextUserAddress();
        vm.startPrank(newAddress);
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        protocolGovernance.changeLiquidationPremium(11 * 10**7);
    }

    function testLiquidationPremiumEventEmitted() public {
        vm.expectEmit(false, true, false, true);
        emit LiquidationPremiumChanged(getNextUserAddress(), address(this), 10**6);
        protocolGovernance.changeLiquidationPremium(10**6);
    }

    // changeMaxDebtPerVault

    function testMaxDebtPerVaultSuccess() public {
        protocolGovernance.changeMaxDebtPerVault(10**25);
        IProtocolGovernance.ProtocolParams memory newParams = protocolGovernance.protocolParams();
        assertEq(newParams.maxDebtPerVault, 10**25);
    }

    function testMaxDebtPerVaultAccessControl() public {
        address newAddress = getNextUserAddress();
        vm.startPrank(newAddress);
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        protocolGovernance.changeMaxDebtPerVault(1);
    }

    function testMaxDebtPerVaultAnyValue() public {
        protocolGovernance.changeMaxDebtPerVault(0);
        protocolGovernance.changeMaxDebtPerVault(type(uint256).max);
        protocolGovernance.changeMaxDebtPerVault(2**100);
        protocolGovernance.changeMaxDebtPerVault(1);
        IProtocolGovernance.ProtocolParams memory newParams = protocolGovernance.protocolParams();
        assertEq(newParams.maxDebtPerVault, 1);
    }

    function testMaxDebtPerVaultEventEmitted() public {
        vm.expectEmit(false, true, false, true);
        emit MaxDebtPerVaultChanged(getNextUserAddress(), address(this), 10**10);
        protocolGovernance.changeMaxDebtPerVault(10**10);
    }

    // changeSingleNftCollateral

    function testChangeMinSingleNftCollateralSuccess() public {
        protocolGovernance.changeMinSingleNftCollateral(10**18);
        IProtocolGovernance.ProtocolParams memory newParams = protocolGovernance.protocolParams();
        assertEq(newParams.minSingleNftCollateral, 10**18);
    }

    function testChangeMinSingleNftCollateralAccessControl() public {
        address newAddress = getNextUserAddress();
        vm.startPrank(newAddress);
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        protocolGovernance.changeMinSingleNftCollateral(10**18);
    }

    function testChangeMinSingleNftCollateralEmitted() public {
        vm.expectEmit(false, true, false, true);
        emit MinSingleNftCollateralChanged(getNextUserAddress(), address(this), 10**20);
        protocolGovernance.changeMinSingleNftCollateral(10**20);
    }

    // changeMaxNftsPerVault

    function testChangeMaxNftsPerVault() public {
        protocolGovernance.changeMaxNftsPerVault(20);
        IProtocolGovernance.ProtocolParams memory newParams = protocolGovernance.protocolParams();
        assertEq(newParams.maxNftsPerVault, 20);
    }

    function testChangeMaxNftsPerVaultAccessControl() public {
        address newAddress = getNextUserAddress();
        vm.startPrank(newAddress);
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        protocolGovernance.changeMaxNftsPerVault(20);
    }

    function testChangeMaxNftsPerVaultEmitted() public {
        vm.expectEmit(false, true, false, true);
        emit MaxNftsPerVaultChanged(getNextUserAddress(), address(this), 20);
        protocolGovernance.changeMaxNftsPerVault(20);
    }

    // setWhitelistedPool

    function testSetWhitelistedPoolZeroAddress() public {
        vm.expectRevert(DefaultAccessControl.AddressZero.selector);
        protocolGovernance.setWhitelistedPool(address(0));
    }

    function testSetWhitelistedPoolAccessControl() public {
        address newAddress = getNextUserAddress();
        vm.startPrank(newAddress);
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        protocolGovernance.setWhitelistedPool(pool);
    }

    function testSetSeveralPoolsOkay() public {
        setPools(protocolGovernance);
    }

    function testSetWhitelistedPoolEmitted() public {
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        vm.expectEmit(false, true, false, true);
        emit WhitelistedPoolSet(getNextUserAddress(), address(this), pool);
        protocolGovernance.setWhitelistedPool(pool);
    }

    // revokeWhitelistedPool

    function testRevokePoolAccessControl() public {
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        protocolGovernance.setWhitelistedPool(pool);
        address newAddress = getNextUserAddress();
        vm.startPrank(newAddress);
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        protocolGovernance.revokeWhitelistedPool(pool);
    }

    function testTryRevokeUnstagedPoolIsOkay() public {
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        protocolGovernance.revokeWhitelistedPool(pool);
    }

    function testRevokePoolEmitted() public {
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        protocolGovernance.setWhitelistedPool(pool);

        vm.expectEmit(false, true, false, true);
        emit WhitelistedPoolRevoked(getNextUserAddress(), address(this), pool);
        protocolGovernance.revokeWhitelistedPool(pool);
    }

    // setLiquidationThreshold

    function testSetThresholdSuccess() public {
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        protocolGovernance.setWhitelistedPool(pool);
        assertEq(protocolGovernance.liquidationThresholdD(pool), 0);
        protocolGovernance.setLiquidationThreshold(pool, 5 * 10**8);
        assertEq(protocolGovernance.liquidationThresholdD(pool), 5 * 10**8);
    }

    function testSetZeroThresholdIsOkay() public {
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        protocolGovernance.setWhitelistedPool(pool);
        protocolGovernance.setLiquidationThreshold(pool, 0);
        assertEq(protocolGovernance.liquidationThresholdD(pool), 0);
    }

    function testSetNewThreshold() public {
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        protocolGovernance.setWhitelistedPool(pool);
        protocolGovernance.setLiquidationThreshold(pool, 5 * 10**8);
        assertEq(protocolGovernance.liquidationThresholdD(pool), 5 * 10**8);
        protocolGovernance.setLiquidationThreshold(pool, 3 * 10**8);
        assertEq(protocolGovernance.liquidationThresholdD(pool), 3 * 10**8);
    }

    function testSetThresholdNotWhitelisted() public {
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        vm.expectRevert(ProtocolGovernance.InvalidPool.selector);
        protocolGovernance.setLiquidationThreshold(pool, 5 * 10**8);
    }

    function testSetThresholdWhitelistedThenRevoked() public {
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        protocolGovernance.setWhitelistedPool(pool);
        protocolGovernance.setLiquidationThreshold(pool, 5 * 10**8);
        protocolGovernance.revokeWhitelistedPool(pool);
        assertEq(protocolGovernance.liquidationThresholdD(pool), 0);
        vm.expectRevert(ProtocolGovernance.InvalidPool.selector);
        protocolGovernance.setLiquidationThreshold(pool, 3 * 10**8);
    }

    function testSetTooLargeThreshold() public {
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        protocolGovernance.setWhitelistedPool(pool);
        vm.expectRevert(ProtocolGovernance.InvalidValue.selector);
        protocolGovernance.setLiquidationThreshold(pool, 2 * 10**9);
    }

    function testSetThresholdZeroAddress() public {
        vm.expectRevert(DefaultAccessControl.AddressZero.selector);
        protocolGovernance.setLiquidationThreshold(address(0), 10**5);
    }

    function testSetThresholdAccessControl() public {
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        address newAddress = getNextUserAddress();
        vm.startPrank(newAddress);
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        protocolGovernance.setLiquidationThreshold(pool, 10**5);
    }

    function testSetThresholdEmitted() public {
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        protocolGovernance.setWhitelistedPool(pool);

        vm.expectEmit(false, true, false, true);
        emit LiquidationThresholdSet(getNextUserAddress(), address(this), pool, 10**6);
        protocolGovernance.setLiquidationThreshold(pool, 10**6);
    }
}
