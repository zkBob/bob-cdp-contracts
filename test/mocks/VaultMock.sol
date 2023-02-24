// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.0;

import "../../src/Vault.sol";
import "forge-std/Test.sol";
import "forge-std/console2.sol";

contract VaultMock is Vault, Test {
    constructor(
        INonfungiblePositionManager positionManager_,
        INFTOracle oracle_,
        address treasury_,
        address token_,
        address vaultRegistry_
    ) Vault(positionManager_, oracle_, treasury_, token_, vaultRegistry_) {}

    function checkInvariantOnVault(uint256 vaultId) external {
        _checkVaultInvariant(vaultId);
        _checkSumInvariant(getOverallDebt(vaultId), vaultMintedDebt[vaultId]);
    }

    function checkInvariantOnVaults(uint256[] memory vaultIds) external {
        uint256 overallDebtSum = 0;
        uint256 mintedDebtSum = 0;
        uint256 len;
        assembly {
            len := mload(add(vaultIds, 0))
        }
        for (uint256 i = 0; i < len; ++i) {
            overallDebtSum += getOverallDebt(vaultIds[i]);
            mintedDebtSum += vaultMintedDebt[vaultIds[i]];
            _checkVaultInvariant(vaultIds[i]);
        }
        _checkSumInvariant(overallDebtSum, mintedDebtSum);
    }

    function debugInfo(uint256 vaultId) public {
        uint256 currentNormalizationRate = _updateRateFee();
        console2.log("PRINTING INFO FOR", vaultId);
        console2.log("ON", block.timestamp);
        console2.log("minted", vaultMintedDebt[vaultId]);
        console2.log("normalized", vaultNormalizedDebt[vaultId]);
        console2.log("overall debt", getOverallDebt(vaultId));
        console2.log("unrealized debt", treasury.surplus());
        console2.log("global debt", _getGlobalDebt());
        console2.log("normalization rate", currentNormalizationRate);
    }

    function _checkSumInvariant(uint256 overallDebtSum, uint256 mintedDebtSum) internal {
        uint256 globalDebt = _getGlobalDebt();
        assertLe(
            treasury.surplus(),
            overallDebtSum - mintedDebtSum,
            "Fees Invariant Failed: global debt must be lower or equal to vault's overall debt"
        );
//        assertGe(globalDebt, mintedDebtSum + treasury.surplus(), "Fees Invariant Failed: global debt must be lower or equal to sum of vault's minted debt and unrealised interest");
    }

    function _checkVaultInvariant(uint256 vaultId) internal {
        uint256 currentNormalizedDebt = vaultNormalizedDebt[vaultId];
        uint256 currentMintedDebt = vaultMintedDebt[vaultId];
        if (currentNormalizedDebt * currentMintedDebt == 0) {
            assertEq(
                currentNormalizedDebt**2 + currentMintedDebt**2,
                0,
                "Fees Invariant Failed: normalized debt and minted debt always must be both equal or unequal to zero"
            );
        }
        assertGe(
            getOverallDebt(vaultId),
            currentMintedDebt,
            "Fees Invariant Failed: overall debt must be greater or equal to minted debt"
        );
    }

    function _getGlobalDebt() internal view returns (uint256) {
        return FullMath.mulDiv(normalizedGlobalDebt, normalizationRate, DEBT_DENOMINATOR);
    }
}
