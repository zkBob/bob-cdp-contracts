// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./AbstractUniswapDeployment.sol";
import "../AbstractPolygonDeployment.sol";

contract UniswapPolygonDeployment is AbstractUniswapDeployment, AbstractPolygonDeployment {
    function ammParams() public pure override returns (address positionManager, address factory) {
        positionManager = address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
        factory = address(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    }
}
