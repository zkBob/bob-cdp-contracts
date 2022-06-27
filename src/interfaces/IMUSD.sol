pragma solidity 0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMUSD is IERC20 {
    function mint(address to, uint256 amount) external;

    function burn(address from, uint256 amount) external;
}
