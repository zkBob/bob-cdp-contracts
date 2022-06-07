// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;


import "./interfaces/IProtocolGovernance.sol";

contract ProtocolGovernance is IProtocolGovernance {
    address private admin;
    address private validator;
    uint256 constant DENOMINATOR = 10 ** 9;
    uint256 private governanceDelay;
    uint256 private stabilisationFeeD;
    uint256 private liquidationFeeD;
    uint256 private liquidationPremiumD;
    uint256 private liguidationThresholds;
    mapping(address => bool) private whitelistedPools;
    uint256 private MAX_DEBT_AMOUNT;
    uint256 private MIN_COLLATERAL_AMOUNT;

    constructor() {

    }
}
