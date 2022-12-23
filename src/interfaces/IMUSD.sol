pragma solidity 0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMUSD is IERC20 {
    // -------------------  EXTERNAL, MUTATING  -------------------

    /// @notice Mint an amount of MUSD for a specified address.
    /// @param to Address of the receiver of MUSD
    /// @param amount Amount of MUSD to mint
    function mint(address to, uint256 amount) external;

    /// @notice Burn an amount of MUSD of a sender.
    /// @param amount Amount of MUSD to burn
    function burn(uint256 amount) external;
}
