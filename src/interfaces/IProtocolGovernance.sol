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
        uint256 liquidationFee;
        uint256 liquidationPremium;
        uint256 maxDebtPerVault;
        uint256 minSingleNftCapital;
    }

    // -------------------  EXTERNAL, VIEW  -------------------

    /// @notice Liquidation threshold for a certain pool (multiplied by DENOMINATOR)
    /// @dev The logic of this parameter is following:
    /// Assume we have nft's n1,...,nk from corresponding pools with liq.thresholds l1,...,lk and real MUSD values v1,...,vk (which can be obtained from Uni info & Chainlink oracle)
    /// Then, a position is healthy <=> (l1 * v1 + ... + lk * vk) <= totalDebt
    /// Hence, 0 <= threshold <= 1 is held
    /// @param pool The given address of pool
    /// @return uint256 Liquidation threshold value (multiplied by DENOMINATOR)
    function liquidationThreshold(address pool) external view returns (uint256);

    /// @notice Global protocol params
    /// @return ProtocolParams Protocol params struct
    function protocolParams() external view returns (ProtocolParams memory);

    /// @notice Check if pool is in the whitelist
    /// @param pool The given address of pool
    /// @return bool True if pool is whitelisted, false if not
    function isPoolWhitelisted(address pool) external view returns (bool);

    /// @notice Token capital limit in all the protocol for a given token (nominated in MUSD weis)
    /// @dev Amount of a token of a certain position is calculated as a maximal amount of token possible in this position taken by all prices
    /// @param token The given address of token
    /// @return uint256 Token capital limit (nominated in MUSD weis) if limit is set, else uint256.max
    function getTokenLimit(address token) external view returns (uint256);

    // -------------------  EXTERNAL, MUTATING  -------------------

    /// @notice Change liquidation fee to a given value
    /// @param liquidationFee The new liquidation fee
    function changeLiquidationFee(uint256 liquidationFee) external;

    /// @notice Change liquidation premium to a given value
    /// @param liquidationPremium The new liquidation premium
    function changeLiquidationPremium(uint256 liquidationPremium) external;

    /// @notice Change max debt per vault to a given value
    /// @param maxDebtPerVault The new max possible debt per vault
    function changeMaxDebtPerVault(uint256 maxDebtPerVault) external;

    /// @notice Change min single nft capital to a given value (nominated in MUSD weis)
    /// @param minSingleNftCapital The new min possible nft capital (nominated in MUSD weis)
    function changeMinSingleNftCapital(uint256 minSingleNftCapital) external;

    /// @notice Add new pool to the whitelist
    /// @param pool Address of the new whitelisted pool
    function setWhitelistedPool(address pool) external;

    /// @notice Revoke pool from the whitelist
    /// @param pool Address of the revoked whitelisted pool
    function revokeWhitelistedPool(address pool) external;

    /// @notice Set liquidation threshold for a given pool
    /// @param pool Address of the pool
    /// @param liquidationRatio The new liquidation ratio
    function setLiquidationThreshold(address pool, uint256 liquidationRatio) external;

    /// @notice Set new capital limit for a given token (in token weis)
    /// @param token Address of the token
    /// @param newLimit The new token capital limit (in token weis)
    function setTokenLimit(address token, uint256 newLimit) external;
}
