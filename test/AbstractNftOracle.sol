// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "./SetupContract.sol";
import "./shared/ForkTests.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

abstract contract AbstractNftOracleTest is SetupContract, AbstractForkTest, AbstractLateSetup {
    uint256 nft;

    function setUp() public {
        vm.createSelectFork(forkRpcUrl, forkBlock);
        _setUp();
        helper.setTokenPrice(oracle, weth, uint256(1200 << 96));
        helper.setTokenPrice(oracle, wbtc, uint256(17000 << 96) * uint256(10 ** 10));
        helper.setApprovals();
        nft = helper.openPosition(weth, wbtc, 20 * (10 ** 18), (10 ** 8), address(0));
        collectEarnings();
    }

    function testPriceOut() public {
        // One side
        nftOracle.price(nft);
        helper.setTokenPrice(oracle, weth, uint256(1500 << 96));
        (, uint256 oldPrice, ) = nftOracle.price(nft);
        helper.setTokenPrice(oracle, weth, uint256(1700 << 96));
        (, uint256 newPrice, ) = nftOracle.price(nft);
        assertEq(oldPrice, newPrice);

        // Other side
        helper.setTokenPrice(oracle, weth, uint256(1200 << 96));
        helper.setTokenPrice(oracle, wbtc, uint256(22000 << 96) * uint256(10 ** 10));
        (, oldPrice, ) = nftOracle.price(nft);
        helper.setTokenPrice(oracle, wbtc, uint256(23000 << 96) * uint256(10 ** 10));
        (, newPrice, ) = nftOracle.price(nft);
        assertEq(oldPrice, newPrice);
    }

    function testPriceIndependentFromSpot() public {
        (, uint256 oldPrice, ) = nftOracle.price(nft);
        helper.makeDesiredPoolPrice(uint256(1 << 96) / uint256(10 ** 10 * 10), weth, wbtc);
        collectEarnings();
        (, uint256 newPrice, ) = nftOracle.price(nft);
        assertEq(oldPrice, newPrice);
        helper.makeDesiredPoolPrice(uint256(1 << 96) / uint256(10 ** 10 * 18), weth, wbtc);
        collectEarnings();
        (, newPrice, ) = nftOracle.price(nft);
        assertEq(oldPrice, newPrice);
    }

    function collectEarnings() internal {
        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: nft,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        INonfungiblePositionManager(PositionManager).collect(collectParams);
    }
}
