// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.13;

import "./ERC721/ERC721Enumerable.sol";
import "./proxy/EIP1967Admin.sol";
import "./interfaces/ICDP.sol";

contract VaultRegistry is EIP1967Admin, ERC721Enumerable {
    /// @notice Thrown when not minter trying to mint
    error Forbidden();

    /// @notice Thrown when user trying to burn nft and has non-empty collateral
    error NonEmptyCollateral();

    /// @notice CDP contract allowed to mint
    ICDP immutable cdp;

    /// @notice Creates a new contract
    /// @param cdp_ CDP contract allowed to mint
    /// @param name_ Token name
    /// @param symbol_ Token's symbol name
    /// @param baseURI_ Token's baseURI
    constructor(
        ICDP cdp_,
        string memory name_,
        string memory symbol_,
        string memory baseURI_
    ) ERC721(name_, symbol_, baseURI_) {
        cdp = cdp_;
    }

    /// @notice Mints a new token
    /// @param to Token receiver
    /// @param tokenId Id of a token
    function mint(address to, uint256 tokenId) external {
        if (msg.sender != address(cdp)) {
            revert Forbidden();
        }
        _mint(to, tokenId);
    }

    /// @notice Burns an existent token
    /// @param tokenId Id of a token
    function burn(uint256 tokenId) external {
        if (msg.sender != ownerOf(tokenId)) {
            revert Forbidden();
        }

        uint256[] memory vaultNfts = cdp.vaultNftsById(tokenId);

        if (vaultNfts.length != 0) {
            revert NonEmptyCollateral();
        }

        _burn(tokenId);
    }
}
