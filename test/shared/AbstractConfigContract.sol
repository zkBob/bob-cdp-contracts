pragma solidity ^0.8.0;

contract AbstractConfigContract {
    address UniV3PositionManager;
    address UniV3Factory;
    address SwapRouter;

    address wbtc;
    address usdc;
    address weth;
    address ape;

    address chainlinkBtc;
    address chainlinkUsdc;
    address chainlinkEth;

    address[] tokens;
    address[] chainlinkOracles;
    uint48[] heartbeats;
}
