// SPDX-License-Identifier: CC0-1.0

pragma solidity ^0.8.0;

interface ITreasury {
    /**
     * @dev Records potential unrealized surplus.
     * Callable only by the pre-approved surplus minter.
     * Once unrealized surplus is realized, it should be transferred to this contract via transferAndCall.
     * @param _surplus unrealized surplus to add.
     */
    function add(uint256 _surplus) external;

    /// @notice Returns current unrealized interest
    /// @return uint256 unrealized interest
    function surplus() external view returns (uint256);
}
