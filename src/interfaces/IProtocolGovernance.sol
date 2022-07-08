// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./utils/IDefaultAccessControl.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IProtocolGovernance is IDefaultAccessControl, IERC165 {
    struct ProtocolParams {
        uint256 liquidationFeeD;
        uint256 liquidationPremiumD;
        uint256 maxDebtPerVault;
        uint256 minSingleNftCollateral;
    }

    // -------------------  EXTERNAL, VIEW  -------------------

    function liquidationThresholdD(address pool) external view returns (uint256);

    function protocolParams() external view returns (ProtocolParams memory);

    function isPoolWhitelisted(address pool) external view returns (bool);

    function getTokenLimit(address token) external view returns (uint256);

    function whitelistedPool(uint256 i) external view returns (address);

    // -------------------  EXTERNAL, MUTATING  -------------------

    function changeLiquidationFee(uint256 liquidationFeeD) external;

    function changeLiquidationPremium(uint256 liquidationPremiumD) external;

    function changeMaxDebtPerVault(uint256 maxDebtPerVault) external;

    function changeMinSingleNftCollateral(uint256 minSingleNftCollateral) external;

    function setWhitelistedPool(address pool) external;

    function revokeWhitelistedPool(address pool) external;

    function setLiquidationThreshold(address pool, uint256 liquidationThresholdD_) external;

    function setTokenLimit(address token, uint256 newLimit) external;
}
