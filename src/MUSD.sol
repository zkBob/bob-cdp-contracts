// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.13;

import "lib/solmate/src/tokens/ERC20.sol";
import "lib/openzeppelin-contracts/contracts/utils/introspection/ERC165.sol";

contract MUSD is ERC20 {

    address public governingVault;

    constructor(string memory name, string memory symbol, address vault) ERC20(name, symbol, 18){
        governingVault = vault;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == governingVault);
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == governingVault);
        _burn(from, amount);
    }
}


