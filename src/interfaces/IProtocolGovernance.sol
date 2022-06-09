// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./utils/IDefaultAccessControl.sol";
import "lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";

interface IProtocolGovernance is IDefaultAccessControl, IERC165 {
    
    struct ProtocolParams {
        uint256 stabilizationFee;
        uint256 liquidationFee;
        uint256 liquidationPremium;
        uint256 maxDebtPerVault;
        uint256 minSingleNftCapital;
        uint256 governanceDelay;
    }

    // -------------------  EXTERNAL, VIEW  -------------------

    function protocolParams() external view returns (ProtocolParams memory);

    function stagedProtocolParams() external view returns (ProtocolParams memory);
    
    function stagedParamsTimestamp() external view returns (uint256);

    function liquidationThreshold(address target) external view returns (uint256);

    function stagedLiquidationThreshold(address target) external view returns (uint256);

    function stagedLiquidationThresholdTimestamp(address target) external view returns (uint256);

    function isTokenPairTotalCapitalLimited(address token0, address token1) external view returns (bool);

    function tokenPairTotalCapitalLimits(address token0, address token1) external view returns (uint256);

    // -------------------  EXTERNAL, MUTATING, GOVERNANCE, IMMEDIATE  -------------------

    function commitParams() external;

    function commitLiquidationThreshold(address pool) external;

    // -------------------  EXTERNAL, MUTATING, GOVERNANCE, DELAY  -------------------

    function stageParams(ProtocolParams calldata newParams) external;

    function stageLiquidationThreshold(address pool, uint256 liquidationRatio) external;

    function stagePairTokensLimit(address token0, address token1, uint256 newLimit) external;

}