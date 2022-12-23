// SPDX-License-Identifer: MIT
pragma solidity 0.8.13;

interface ICDP {
    /// @notice Get all NFTs, managed by vault with given id
    /// @param vaultId Id of the vault
    /// @return uint256[] Array of NFTs, managed by vault
    function vaultNftsById(uint256 vaultId) external view returns (uint256[] memory);
}
