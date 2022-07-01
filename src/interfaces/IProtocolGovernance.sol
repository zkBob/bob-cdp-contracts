// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./utils/IDefaultAccessControl.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IProtocolGovernance is IDefaultAccessControl, IERC165 {
    /// @notice Global protocol params.
    /// @param liquidationFee Part of the funds on vault, transfered to Protocol Treasury after liquidation
    /// @param liquidationPremium Amount of fees given to liquidator after liquidation
    /// @param maxDebtPerVault Max possible debt for each vault
    /// @param minSingleNftCapital Min possible NFT capitalisation for each position
    struct ProtocolParams {
        uint256 liquidationFee;
        uint256 liquidationPremium;
        uint256 maxDebtPerVault;
        uint256 minSingleNftCapital;
    }

    // -------------------  EXTERNAL, VIEW  -------------------

    /// @notice Liquidation threshold for certain pool.
    /// @param pool The given address of pool
    /// @return Liquidation threshold value
    function liquidationThreshold(address pool) external view returns (uint256);

    /// @notice Global protocol params.
    /// @return Protocol params struct
    function protocolParams() external view returns (ProtocolParams memory);

    /// @notice Check if pool is in the whitelist or not.
    /// @param pool The given address of pool
    /// @return True if pool is whitelisted, else returns false
    function isPoolWhitelisted(address pool) external view returns (bool);

    /// @notice Token capital limit for each token address.
    /// @param token The given address of token
    /// @return Token capital limit if limit is set, else uint256.max
    function getTokenLimit(address token) external view returns (uint256);

    // -------------------  EXTERNAL, MUTATING  -------------------

    /// @notice Change liquidation fee to a given value.
    /// @param liquidationFee The new liquidation fee
    function changeLiquidationFee(uint256 liquidationFee) external;

    /// @notice Change liquidation premium to a given value.
    /// @param liquidationPremium The new liquidation premium
    function changeLiquidationPremium(uint256 liquidationPremium) external;

    /// @notice Change max debt per vault to a given value.
    /// @param maxDebtPerVault The new max possible debt per vault
    function changeMaxDebtPerVault(uint256 maxDebtPerVault) external;

    /// @notice Change min single nft capital to a given value.
    /// @param minSingleNftCapital The new min possible nft capital
    function changeMinSingleNftCapital(uint256 minSingleNftCapital) external;

    /// @notice Add new pool to the whitelist.
    /// @param pool Address of the new whitelisted pool
    function setWhitelistedPool(address pool) external;

    /// @notice Delete pool from the whitelist.
    /// @param pool Address of the deleted whitelisted pool
    function revokeWhitelistedPool(address pool) external;

    /// @notice Set liquidation threshold for a given pool.
    /// @param pool Address of the pool
    /// @param liquidationRatio The new liquidation ratio
    function setLiquidationThreshold(address pool, uint256 liquidationRatio) external;

    /// @notice Set new capital limit for a given token.
    /// @param token Address of the token
    /// @param newLimit The new token capital limit
    function setTokenLimit(address token, uint256 newLimit) external;
}
