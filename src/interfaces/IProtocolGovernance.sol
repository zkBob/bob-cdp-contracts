// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./utils/IDefaultAccessControl.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IProtocolGovernance is IDefaultAccessControl, IERC165 {
    struct ProtocolParams {
        uint256 stabilizationFee;
        uint256 liquidationFee;
        uint256 liquidationPremium;
        uint256 maxDebtPerVault;
        uint256 minSingleNftCapital;
    }

    // -------------------  EXTERNAL, VIEW  -------------------

    function liquidationThreshold(address pool) external view returns (uint256);

    function protocolParams() external view returns (ProtocolParams memory);

    function isPoolWhitelisted(address pool) external view returns (bool);

    function getTokenLimit(address token) external view returns (uint256);

    // -------------------  EXTERNAL, MUTATING  -------------------

    function changeStabilizationFee(uint256 stabilizationFee) external;

    function changeLiquidationFee(uint256 liquidationFee) external;

    function changeLiquidationPremium(uint256 liquidationPremium) external;

    function changeMaxDebtPerVault(uint256 maxDebtPerVault) external;

    function changeMinSingleNftCapital(uint256 minSingleNftCapital) external;

    function setWhitelistedPool(address pool) external;

    function revokeWhitelistedPool(address pool) external;

    function setLiquidationThreshold(address pool, uint256 liquidationRatio) external;

    function setTokenLimit(address token, uint256 newLimit) external;
}
