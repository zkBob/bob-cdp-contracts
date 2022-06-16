// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

/// @notice Errors stores project`s smart-contracts errors
library ExceptionsLibrary {
    error AddressZero();
    error Duplicate();
    error Forbidden();
    error InvalidValue();
    error InvalidLength(uint256 actualLength, uint256 targetLength);
    error Null();
    error Timestamp();
    error ValueZero();
}
