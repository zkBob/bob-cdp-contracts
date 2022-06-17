// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

/// @notice Errors stores project`s smart-contracts errors
library ExceptionsLibrary {
    error AddressZero();
    error AllowList();
    error DebtOverflow();
    error Duplicate();
    error Forbidden();
    error InvalidLength(uint256 actualLength, uint256 targetLength);
    error InvalidPool();
    error InvalidValue();
    error Null();
    error PositionHealthy();
    error PositionUnhealthy();
    error Timestamp();
    error UnpaidDebt();
    error ValueZero();
}
