// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./AbstractQuickswapDeployment.sol";
import "../AbstractPolygonDeployment.sol";

contract QuickswapPolygonDeployment is AbstractQuickswapDeployment, AbstractPolygonDeployment {
    function ammParams() public pure override returns (address positionManager, address factory) {
        positionManager = address(0x8eF88E4c7CfbbaC1C163f7eddd4B578792201de6);
        factory = address(0x411b0fAcC3489691f28ad58c47006AF5E3Ab3A28);
    }
}
