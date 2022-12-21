// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.13;

import "@solmate/src/tokens/ERC20.sol";

contract MUSD is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol, 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
