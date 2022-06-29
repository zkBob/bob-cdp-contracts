pragma solidity 0.8.13;

abstract contract ConfigContract {
    address constant UniV3PositionManager = address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    address constant UniV3Factory = address(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    address constant SwapRouter = address(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    address constant wbtc = address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    address constant usdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address constant ape = address(0x4d224452801ACEd8B2F0aebE155379bb5D594381);

    address constant chainlinkBtc = address(0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c);
    address constant chainlinkUsdc = address(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
    address constant chainlinkEth = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);

    address[] tokens = [wbtc, usdc, weth];
    address[] chainlinkOracles = [chainlinkBtc, chainlinkUsdc, chainlinkEth];
}
