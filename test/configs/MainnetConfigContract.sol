pragma solidity 0.8.13;

contract MainnetConfigContract {
    address public constant UniV3PositionManager = address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    address public constant UniV3Factory = address(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    address public constant SwapRouter = address(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    address public constant wbtc = address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    address public constant usdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address public constant weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address public constant ape = address(0x4d224452801ACEd8B2F0aebE155379bb5D594381);

    address public constant chainlinkBtc = address(0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c);
    address public constant chainlinkUsdc = address(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
    address public constant chainlinkEth = address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);

    uint256 public constant Q96 = 2**96;
    uint256 public constant Q48 = 2**48;

    address[] public tokens = [wbtc, usdc, weth];
    address[] public chainlinkOracles = [chainlinkBtc, chainlinkUsdc, chainlinkEth];
    uint48[] public heartbeats = [1500, 36000, 1500];
}
