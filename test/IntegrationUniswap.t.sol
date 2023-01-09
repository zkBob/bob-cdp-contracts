// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./AbstractIntegration.t.sol";
import "./shared/AbstractUniswapHelper.sol";

abstract contract AbstractUniswapIntegrationTestForVault is AbstractIntegrationTestForVault {
    function testReasonablePoolFeesCalculating() public {
        uint256 vaultId = vault.openVault();
        uint256 nftA = helper.openPosition(weth, usdc, 10**18, 10**9, address(vault));
        vault.depositCollateral(vaultId, nftA);

        (, uint256 healthBeforeSwaps) = vault.calculateVaultCollateral(vaultId);
        vault.mintDebt(vaultId, healthBeforeSwaps - 1);

        vm.expectRevert(Vault.PositionUnhealthy.selector);
        vault.mintDebt(vaultId, 100);

        helper.setTokenPrice(oracle, weth, 999 << 96); // small price change to make position slightly lower than health threshold
        (, uint256 healthAfterPriceChanged) = vault.calculateVaultCollateral(vaultId);
        uint256 debt = vault.vaultDebt(vaultId);

        assertTrue(healthAfterPriceChanged <= debt);

        uint256 amountOut = helper.makeSwap(weth, usdc, 10**22); // have to get a lot of fees
        helper.makeSwap(usdc, weth, amountOut);

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
}

contract MainnetUniswapIntegrationTestForVault is
    AbstractUniswapIntegrationTestForVault,
    AbstractMainnetForkTest,
    AbstractMainnetUniswapConfigContract,
    MainnetUniswapTestSuite
{}

contract PolygonUniswapIntegrationTestForVault is
    AbstractUniswapIntegrationTestForVault,
    AbstractPolygonForkTest,
    AbstractPolygonUniswapConfigContract,
    PolygonUniswapTestSuite
{}
