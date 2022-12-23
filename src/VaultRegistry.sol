// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.13;

import "./ERC721/ERC721Enumerable.sol";
import "./proxy/EIP1967Admin.sol";

contract VaultRegistry is EIP1967Admin, ERC721Enumerable {
    /// @notice Thrown when not minter trying to mint
    error Forbidden();

    /// @notice Address allowed to mint
    address immutable minter;

    /// @notice Creates a new contract
    /// @param minter_ Address allowed to mint
    /// @param name_ Token name
    /// @param symbol_ Token's symbol name
    /// @param baseURI_ Token's baseURI
    constructor(
        address minter_,
        string memory name_,
        string memory symbol_,
        string memory baseURI_
    ) ERC721(name_, symbol_, baseURI_) {
        minter = minter_;
    }

    /// @notice Mints a new token
    /// @param to Token receiver
    /// @param tokenId Id of a token
    function mint(address to, uint256 tokenId) external {
        if (msg.sender != minter) {
            revert Forbidden();
        }
        _mint(to, tokenId);
    }
}