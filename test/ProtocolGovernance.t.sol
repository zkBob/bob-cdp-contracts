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
    event StabilizationFeeChanged(address indexed origin, address indexed sender, uint256 indexed stabilizationFee);
    event LiquidationFeeChanged(address indexed origin, address indexed sender, uint256 indexed liquidationFee);
    event LiquidationPremiumChanged(address indexed origin, address indexed sender, uint256 indexed liquidationPremium);
    event MaxDebtPerVaultChanged(address indexed origin, address indexed sender, uint256 indexed maxDebtPerVault);
    event MinSingleNftCapitalChanged(
        address indexed origin,
        address indexed sender,
        uint256 indexed minSingleNftCapital
    );
    event WhitelistedPoolSet(address indexed origin, address indexed sender, address indexed pool);
    event WhitelistedPoolRevoked(address indexed origin, address indexed sender, address indexed pool);
    event TokenLimitSet(address indexed origin, address indexed sender, address token, uint256 stagedLimit);
    event LiquidationThresholdSet(
        address indexed origin,
        address indexed sender,
        address indexed pool,
        uint256 liquidationRatio
    );

    ProtocolGovernance protocolGovernance;

    function setUp() public {
        protocolGovernance = new ProtocolGovernance(address(this));
    }

    function testDefaultProtocolParams() public {
        IProtocolGovernance.ProtocolParams memory params = protocolGovernance.protocolParams();
        assertEq(params.stabilizationFee, 0);
        assertEq(params.liquidationFee, 0);
        assertEq(params.liquidationPremium, 0);
        assertEq(params.maxDebtPerVault, type(uint256).max);
        assertEq(params.minSingleNftCapital, 0);
    }

    function testChangedProtocolParams() public {
        protocolGovernance.changeStabilizationFee(5 * 10**7);
        protocolGovernance.changeLiquidationFee(3 * 10**7);
        protocolGovernance.changeLiquidationPremium(3 * 10**7);
        protocolGovernance.changeMaxDebtPerVault(10**24);
        protocolGovernance.changeMinSingleNftCapital(10**18);
        IProtocolGovernance.ProtocolParams memory newParams = protocolGovernance.protocolParams();
        assertEq(newParams.stabilizationFee, 5 * 10**7);
        assertEq(newParams.liquidationFee, 3 * 10**7);
        assertEq(newParams.liquidationPremium, 3 * 10**7);
        assertEq(newParams.maxDebtPerVault, 10**24);
        assertEq(newParams.minSingleNftCapital, 10**18);
    }

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

    function testTokenLimitSuccess() public {
        address token = usdc;
        uint256 limit = protocolGovernance.getTokenLimit(token);
        assertEq(limit, type(uint256).max);
    }

    function testTokenLimitSet() public {
        address token = usdc;
        protocolGovernance.setTokenLimit(token, 1000);
        uint256 limit = protocolGovernance.getTokenLimit(token);
        assertEq(limit, 1000);
    }

    function testTokenRevokedAndReturned() public {
        address token = usdc;
        protocolGovernance.setTokenLimit(token, 0);
        uint256 limit = protocolGovernance.getTokenLimit(token);
        assertEq(limit, 0);

        protocolGovernance.setTokenLimit(token, 10**50);
        uint256 newLimit = protocolGovernance.getTokenLimit(token);
        assertEq(newLimit, 10**50);
    }

    function testSupportsInterfaceId() public {
        bytes4 interfaceId = 0xc25a553e;
        assertTrue(protocolGovernance.supportsInterface(interfaceId));
    }

    function testNotSupportsInterfaceId() public {
        bytes4 randomString = 0xabc00012;
        assertTrue(!protocolGovernance.supportsInterface(randomString));
    }

    function testAccessControlsAllAccountsMethods() public {
        address newAddress = getNextUserAddress();
        vm.startPrank(newAddress);

        protocolGovernance.protocolParams();
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        protocolGovernance.isPoolWhitelisted(pool);
        protocolGovernance.getTokenLimit(usdc);
        protocolGovernance.liquidationThreshold(usdc);
    }

    function testStabilizationFeeSuccess() public {
        protocolGovernance.changeStabilizationFee(5 * 10**7);
        IProtocolGovernance.ProtocolParams memory newParams = protocolGovernance.protocolParams();
        assertEq(newParams.stabilizationFee, 5 * 10**7);
    }

    function testStabilizationFeeTooLarge() public {
        vm.expectRevert(ProtocolGovernance.InvalidValue.selector);
        protocolGovernance.changeStabilizationFee(2 * 10**9);
    }

    function testStabilizationFeeAccessControl() public {
        address newAddress = getNextUserAddress();
        vm.startPrank(newAddress);
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        protocolGovernance.changeStabilizationFee(5 * 10**7);
    }

    function testStabilizationFeeEventEmitted() public {
        vm.expectEmit(false, true, true, false);
        emit StabilizationFeeChanged(getNextUserAddress(), address(this), 5 * 10**7);
        protocolGovernance.changeStabilizationFee(5 * 10**7);
    }

    function testLiquidationFeeSuccess() public {
        protocolGovernance.changeLiquidationFee(10**8);
        IProtocolGovernance.ProtocolParams memory newParams = protocolGovernance.protocolParams();
        assertEq(newParams.liquidationFee, 10**8);
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
        vm.expectEmit(false, true, true, false);
        emit LiquidationFeeChanged(getNextUserAddress(), address(this), 10 ** 6);
        protocolGovernance.changeLiquidationFee(10 ** 6);
    }

    function testLiquidationPremiumSuccess() public {
        protocolGovernance.changeLiquidationPremium(10**8);
        IProtocolGovernance.ProtocolParams memory newParams = protocolGovernance.protocolParams();
        assertEq(newParams.liquidationPremium, 10**8);
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
        vm.expectEmit(false, true, true, false);
        emit LiquidationPremiumChanged(getNextUserAddress(), address(this), 10 ** 6);
        protocolGovernance.changeLiquidationPremium(10 ** 6);
    }

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
        vm.expectEmit(false, true, true, false);
        emit MaxDebtPerVaultChanged(getNextUserAddress(), address(this), 10**10);
        protocolGovernance.changeMaxDebtPerVault(10**10);
    }

    function testChangeMinSingleNftCapitalSuccess() public {
        protocolGovernance.changeMinSingleNftCapital(10**18);
        IProtocolGovernance.ProtocolParams memory newParams = protocolGovernance.protocolParams();
        assertEq(newParams.minSingleNftCapital, 10**18);
    }

    function testChangeMinSingleNftCapitalTooLarge() public {
        vm.expectRevert(ProtocolGovernance.InvalidValue.selector);
        protocolGovernance.changeMinSingleNftCapital(21 * 10**18 * 10_000);
    }

    function testChangeMinSingleNftCapitalAccessControl() public {
        address newAddress = getNextUserAddress();
        vm.startPrank(newAddress);
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        protocolGovernance.changeMinSingleNftCapital(10**18);
    }

    function testChangeMinSingleNftCapitalEmitted() public {
        vm.expectEmit(false, true, true, false);
        emit MinSingleNftCapitalChanged(getNextUserAddress(), address(this), 10**20);
        protocolGovernance.changeMinSingleNftCapital(10**20);
    }

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
        vm.expectEmit(false, true, true, false);
        emit WhitelistedPoolSet(getNextUserAddress(), address(this), pool);
        protocolGovernance.setWhitelistedPool(pool);
    }

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

        vm.expectEmit(false, true, true, false);
        emit WhitelistedPoolRevoked(getNextUserAddress(), address(this), pool);
        protocolGovernance.revokeWhitelistedPool(pool);
    }

    function testSetTokenLimitAccessControl() public {
        address token = usdc;

        address newAddress = getNextUserAddress();
        vm.startPrank(newAddress);
        vm.expectRevert(DefaultAccessControl.Forbidden.selector);
        protocolGovernance.setTokenLimit(token, 10**18);
    }

    function testSetZeroAddress() public {
        vm.expectRevert(DefaultAccessControl.AddressZero.selector);
        protocolGovernance.setTokenLimit(address(0), 10**18);
    }

    function testSetTokenLimitEmitted() public {
        address token = usdc;

        vm.expectEmit(false, true, true, true);
        emit TokenLimitSet(getNextUserAddress(), address(this), token, 10**18);
        protocolGovernance.setTokenLimit(token, 10**18);
    }

    function testSetThresholdSuccess() public {
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        protocolGovernance.setWhitelistedPool(pool);
        assertEq(protocolGovernance.liquidationThreshold(pool), 0);
        protocolGovernance.setLiquidationThreshold(pool, 5 * 10**8);
        assertEq(protocolGovernance.liquidationThreshold(pool), 5 * 10**8);
    }

    function testSetZeroThresholdIsOkay() public {
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        protocolGovernance.setWhitelistedPool(pool);
        protocolGovernance.setLiquidationThreshold(pool, 0);
        assertEq(protocolGovernance.liquidationThreshold(pool), 0);
    }

    function testSetNewThreshold() public {
        address pool = IUniswapV3Factory(UniV3Factory).getPool(weth, usdc, 3000);
        protocolGovernance.setWhitelistedPool(pool);
        protocolGovernance.setLiquidationThreshold(pool, 5 * 10**8);
        assertEq(protocolGovernance.liquidationThreshold(pool), 5 * 10**8);
        protocolGovernance.setLiquidationThreshold(pool, 3 * 10**8);
        assertEq(protocolGovernance.liquidationThreshold(pool), 3 * 10**8);
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
        assertEq(protocolGovernance.liquidationThreshold(pool), 0);
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

        vm.expectEmit(false, true, true, true);
        emit LiquidationThresholdSet(getNextUserAddress(), address(this), pool, 10**6);
        protocolGovernance.setLiquidationThreshold(pool, 10**6);
    }

}
