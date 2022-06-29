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

    function testWhitelistedPoolSuccess() public {
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

}
