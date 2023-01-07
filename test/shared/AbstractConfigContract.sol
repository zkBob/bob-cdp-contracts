// SPDX-License-Identifier: CC0-1.0

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./interfaces/IHelper.sol";

contract AbstractConfigContract {
    address PositionManager;
    address Factory;
    address SwapRouter;

    IHelper helper;

    address wbtc;
    address usdc;
    address weth;
    address dai;

    address chainlinkBtc;
    address chainlinkUsdc;
    address chainlinkEth;

    address[] tokens;
    address[] chainlinkOracles;
    uint48[] heartbeats;

    // openPosition support
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes memory data
    ) external returns (bytes4) {
        address approveAddress = abi.decode(data, (address));

        if (approveAddress != address(0)) {
            IERC721(msg.sender).approve(approveAddress, tokenId);
        }

        return this.onERC721Received.selector;
    }
}

abstract contract AbstractMainnetUniswapConfigContract is AbstractConfigContract {
    constructor() {
        PositionManager = address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
        Factory = address(0x1F98431c8aD98523631AE4a59f267346ea31F984);
        SwapRouter = address(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    }
}

abstract contract AbstractPolygonUniswapConfigContract is AbstractConfigContract {
    constructor() {
        PositionManager = address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
        Factory = address(0x1F98431c8aD98523631AE4a59f267346ea31F984);
        SwapRouter = address(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    }
}

abstract contract AbstractPolygonQuickswapConfigContract is AbstractConfigContract {
    constructor() {
        PositionManager = address(0x8eF88E4c7CfbbaC1C163f7eddd4B578792201de6);
        Factory = address(0x411b0fAcC3489691f28ad58c47006AF5E3Ab3A28);
        SwapRouter = address(0xf5b509bB0909a69B1c207E495f687a596C168E12);
    }
}
