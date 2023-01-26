// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

interface IVaultRegistry is IERC721Enumerable {
    /// @notice Checks if user is authorized to manage specific token id
    /// Only token owner or approved operators are allowed to manage a specific token id
    /// @param tokenId Id of a token
    /// @param user Address of the manager
    /// @return true if user is authorized, false otherwise
    function isAuthorized(uint256 tokenId, address user) external view returns (bool);

    /// @notice Mints a new token
    /// @param to Token receiver
    /// @return minted token id
    function mint(address to) external returns (uint256);

    /// @notice Burns an existent token
    /// Only the minter of the specified token id is allowed to burn it
    /// @param tokenId Id of a token
    function burn(uint256 tokenId) external;
}
