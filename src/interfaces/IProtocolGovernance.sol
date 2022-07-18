// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./utils/IDefaultAccessControl.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IProtocolGovernance is IDefaultAccessControl, IERC165 {
    /// @notice Global protocol params
    /// @param liquidationFee Share of the MUSD value of assets of a vault, due to be transferred to the Protocol Treasury after a liquidation (multiplied by DENOMINATOR)
    /// @param liquidationPremium Share of the MUSD value of assets of a vault, due to be awarded to a liquidator after a liquidation (multiplied by DENOMINATOR)
    /// @param maxDebtPerVault Max possible debt for one vault (nominated in MUSD weis)
    /// @param minSingleNftCapital Min possible MUSD NFT value allowed to deposit (nominated in MUSD weis)
    struct ProtocolParams {
        uint256 liquidationFeeD;
        uint256 liquidationPremiumD;
        uint256 maxDebtPerVault;
        uint256 minSingleNftCollateral;
    }

    // -------------------  EXTERNAL, VIEW  -------------------

    /// @notice Liquidation threshold for a certain pool (multiplied by DENOMINATOR)
    /// @dev The logic of this parameter is following:
    /// Assume we have nft's n1,...,nk from corresponding pools with liq.thresholds l1,...,lk and real MUSD values v1,...,vk (which can be obtained from Uni info & Chainlink oracle)
    /// Then, a position is healthy <=> (l1 * v1 + ... + lk * vk) <= totalDebt
    /// Hence, 0 <= threshold <= 1 is held
    /// @param pool The given address of pool
    /// @return uint256 Liquidation threshold value (multiplied by DENOMINATOR)
    function liquidationThresholdD(address pool) external view returns (uint256);

    /// @notice Global protocol params
    /// @return ProtocolParams Protocol params struct
    function protocolParams() external view returns (ProtocolParams memory);

    /// @notice Check if pool is in the whitelist
    /// @param pool The given address of pool
    /// @return bool True if pool is whitelisted, false if not
    function isPoolWhitelisted(address pool) external view returns (bool);

    /// @notice Get a whitelisted pool by its index
    /// @param i Index of the pool
    /// @return address Address of the pool
    function whitelistedPool(uint256 i) external view returns (address);

    // -------------------  EXTERNAL, MUTATING  -------------------

    /// @notice Change liquidation fee (multiplied by DENOMINATOR) to a given value
    /// @param liquidationFeeD The new liquidation fee (multiplied by DENOMINATOR)
    function changeLiquidationFee(uint256 liquidationFeeD) external;

    /// @notice Change liquidation premium (multiplied by DENOMINATOR) to a given value
    /// @param liquidationPremiumD The new liquidation premium (multiplied by DENOMINATOR)
    function changeLiquidationPremium(uint256 liquidationPremiumD) external;

    /// @notice Change max debt per vault (nominated in MUSD weis) to a given value
    /// @param maxDebtPerVault The new max possible debt per vault (nominated in MUSD weis)
    function changeMaxDebtPerVault(uint256 maxDebtPerVault) external;

    /// @notice Change min single nft collateral to a given value (nominated in MUSD weis)
    /// @param minSingleNftCollateral The new min possible nft collateral (nominated in MUSD weis)
    function changeMinSingleNftCollateral(uint256 minSingleNftCollateral) external;

    /// @notice Add a new pool to the whitelist
    /// @param pool Address of the new whitelisted pool
    function setWhitelistedPool(address pool) external;

    /// @notice Revoke a pool from the whitelist
    /// @param pool Address of the revoked whitelisted pool
    function revokeWhitelistedPool(address pool) external;

    /// @notice Set liquidation threshold (multiplied by DENOMINATOR) for a given pool
    /// @param pool Address of the pool
    /// @param liquidationThresholdD_ The new liquidation threshold (multiplied by DENOMINATOR)
    function setLiquidationThreshold(address pool, uint256 liquidationThresholdD_) external;
}
