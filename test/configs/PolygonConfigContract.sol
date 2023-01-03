pragma solidity 0.8.13;

abstract contract PolygonConfigContract {
    address constant UniV3PositionManager = address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    address constant UniV3Factory = address(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    address constant SwapRouter = address(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    address constant wbtc = address(0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6);
    address constant usdc = address(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);
    address constant weth = address(0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619);
    address constant ape = address(0xB7b31a6BC18e48888545CE79e83E06003bE70930);

    address constant chainlinkBtc = address(0xc907E116054Ad103354f2D350FD2514433D57F6f);
    address constant chainlinkUsdc = address(0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7);
    address constant chainlinkEth = address(0xF9680D99D6C9589e2a93a78A04A279e509205945);

    address[] tokens = [wbtc, usdc, weth];
    address[] chainlinkOracles = [chainlinkBtc, chainlinkUsdc, chainlinkEth];
}
