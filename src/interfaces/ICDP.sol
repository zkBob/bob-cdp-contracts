// SPDX-License-Identifer: MIT
pragma solidity ^0.8.0;

interface ICDP {
    /// @notice Global protocol params
    /// @param maxDebtPerVault Max possible debt for one vault (nominated in MUSD weis)
    /// @param minSingleNftCapital Min possible MUSD NFT value allowed to deposit (nominated in MUSD weis)
    /// @param liquidationFee Share of the MUSD value of assets of a vault, due to be transferred to the Protocol Treasury after a liquidation (multiplied by DENOMINATOR)
    /// @param liquidationPremium Share of the MUSD value of assets of a vault, due to be awarded to a liquidator after a liquidation (multiplied by DENOMINATOR)
    /// @param maxNftsPerVault Max possible amount of NFTs for one vault
    struct ProtocolParams {
        uint256 maxDebtPerVault;
        uint256 minSingleNftCollateral;
        uint32 liquidationFeeD;
        uint32 liquidationPremiumD;
        uint8 maxNftsPerVault;
    }

    /// @notice Collateral pool params
    /// @param liquidationThreshold collateral liquidation threshold (9 decimals)
    /// @param borrowThreshold maximum borrow threshold, should be less than or equal to liquidationThreshold (9 decimals)
    /// @param minWidth min allowed position width in UniV3 ticks
    struct PoolParams {
        uint32 liquidationThreshold;
        uint32 borrowThreshold;
        uint24 minWidth;
    }

    // -------------------  EXTERNAL, VIEW  -------------------

    /// @notice Get all NFTs, managed by vault with given id
    /// @param vaultId Id of the vault
    /// @return uint256[] Array of NFTs, managed by vault
    function vaultNftsById(uint256 vaultId) external view returns (uint256[] memory);

    /// @notice Global protocol params
    /// @return ProtocolParams Protocol params struct
    function protocolParams() external view returns (ProtocolParams memory);

    /// @notice Tells pool collateral params.
    /// @param pool address of collateral pool.
    /// @return pool params struct
    function poolParams(address pool) external view returns (PoolParams memory);

    /// @notice Get total debt for a given vault by id (including fees)
    /// @param vaultId Id of the vault
    /// @return uint256 Total debt value (in MUSD weis)
    function getOverallDebt(uint256 vaultId) external view returns (uint256);

    // -------------------  EXTERNAL, MUTATING  -------------------

    /// @notice Change liquidation fee (multiplied by DENOMINATOR) to a given value
    /// @param liquidationFeeD The new liquidation fee (multiplied by DENOMINATOR)
    function changeLiquidationFee(uint32 liquidationFeeD) external;

    /// @notice Change liquidation premium (multiplied by DENOMINATOR) to a given value
    /// @param liquidationPremiumD The new liquidation premium (multiplied by DENOMINATOR)
    function changeLiquidationPremium(uint32 liquidationPremiumD) external;

    /// @notice Change max debt per vault (nominated in MUSD weis) to a given value
    /// @param maxDebtPerVault The new max possible debt per vault (nominated in MUSD weis)
    function changeMaxDebtPerVault(uint256 maxDebtPerVault) external;

    /// @notice Change min single nft collateral to a given value (nominated in MUSD weis)
    /// @param minSingleNftCollateral The new min possible nft collateral (nominated in MUSD weis)
    function changeMinSingleNftCollateral(uint256 minSingleNftCollateral) external;

    /// @notice Change max possible amount of NFTs for one vault
    /// @param maxNftsPerVault The new max possible amount of NFTs for one vault
    function changeMaxNftsPerVault(uint8 maxNftsPerVault) external;

    /// @notice Change whitelisted pool parameters
    /// @param pool address of the pool contract to change params for
    /// @param params new collateral params
    function setPoolParams(address pool, ICDP.PoolParams calldata params) external;

    /// @notice Liquidate a vault
    /// @param vaultId Id of the vault subject to liquidation
    function liquidate(uint256 vaultId) external;

    /// @notice Withdraws vault owed tokens, left after liquidation
    /// @param vaultId id of the liquidated vault
    /// @param to address where to sent withdrawn tokens
    /// @param maxAmount max amount of tokens to withdraw
    /// @return withdrawnAmount final amount of withdrawn tokens
    function withdrawOwed(
        uint256 vaultId,
        address to,
        uint256 maxAmount
    ) external returns (uint256 withdrawnAmount);

    /// @notice Calculate adjusted collateral for a given vault (token capitals of each specific collateral in the vault in MUSD weis)
    /// @param vaultId Id of the vault
    /// @return total Total vault collateral value
    /// @return borrowLimit Borrow limit
    /// @return liquidationLimit Debt liquidation limit
    function calculateVaultCollateral(uint256 vaultId)
        external
        view
        returns (
            uint256 total,
            uint256 borrowLimit,
            uint256 liquidationLimit
        );
}
