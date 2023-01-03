// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

interface IVaultRegistry is IERC721Enumerable {
    /// @notice Mints a new token
    /// @param to Token receiver
    /// @param tokenId Id of a token
    function mint(address to, uint256 tokenId) external;

    /// @notice Burns an existent token
    /// @param tokenId Id of a token
    function burn(uint256 tokenId) external;
}
