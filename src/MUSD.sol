// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.13;

import "@solmate/src/tokens/ERC20.sol";

/// @notice Contract of the stable token MUSD
contract MUSD is ERC20 {
    /// @notice Thrown when a user has not permissions to perform a certain action.
    error Forbidden();

    /// @notice The only vault, which is allowed to mint or burn MUSD (remains constant after contract creation).
    address public immutable governingVault;

    /// @notice Creates a new contract.
    /// @param name ERC20 token name
    /// @param symbol ERC20 token symbol
    /// @param vault Address of the governing vault
    constructor(
        string memory name,
        string memory symbol,
        address vault
    ) ERC20(name, symbol, 18) {
        governingVault = vault;
    }

    // -------------------  EXTERNAL, MUTATING  -------------------

    /// @notice Mint an amount of MUSD for a specified address.
    /// @param to Address of the receiver of MUSD
    /// @param amount Amount of MUSD to mint
    function mint(address to, uint256 amount) external {
        if (msg.sender != governingVault) {
            revert Forbidden();
        }
        _mint(to, amount);
    }

    /// @notice Burn an amount of MUSD of a specified address.
    /// @param from Address of the holder of MUSD
    /// @param amount Amount of MUSD to burn
    function burn(address from, uint256 amount) external {
        if (msg.sender != governingVault) {
            revert Forbidden();
        }
        _burn(from, amount);
    }
}
