// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./interfaces/oracles/IOracle.sol";
import "./interfaces/external/univ3/INonfungiblePositionManager.sol";
import "./utils/DefaultAccessControl.sol";
import "../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import "../lib/openzeppelin-contracts/contracts/mocks/EnumerableSetMock.sol";

contract Vault is DefaultAccessControl {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    bool public isPaused = false;
    bool public isPrivate = false;
    INonfungiblePositionManager public immutable positionManager;
    IOracle public oracle;
    IProtocolGovernance public protocolGovernance;
    EnumerableSet.AddressSet private _depositorsAllowlist;
    mapping(address => EnumerableSet.UintSet) public ownedVaults;
    mapping(uint256 => EnumerableSet.UintSet) public vaultNfts;
    mapping(uint256 => uint256) public debt;
    uint256 vaultCount = 0;

    function ownedVaults(address target) external view returns (uint256[] memory) {
        return ownedVaults[target].values();
    }

    function depositorsAllowlist() external view returns (address[] memory) {
        return _depositorsAllowlist.values();
    }

    function openVault() external returns (uint256 vaultId) {
        ++vaultCount;
        ownedVaults[msg.sender].add(vaultCount);
        return vaultCount;
    }

    function closeVault(uint256 vaultId) external {
        require(ownedVaults[msg.sender].contains(vaultId), ExceptionsLibrary.FORBIDDEN);
        require(debt[vaultId] == 0, ExceptionsLibrary.UNPAID_DEBT);
        _closeVault(vaultId, msg.sender, msg.sender);
    }

    function _closeVault(uint256 vaultId, address vaultOwner, address nftsRecipient) internal {
        uint256[] memory nfts = vaultNfts[];

        for (uint256 i = 0; i < nfts.length(); ++i) {
            positionManager.safeTransferFrom(address(this), nftsRecipient, nfts[i]);
        }

        delete debt[vaultId];
        ownedVaults[vaultOwner].remove(vaultId);
        delete vaultNfts[vaultId];
    }


    function addDepositorsToAllowlist(address[] calldata depositors) external {
        _requireAdmin();
        for (uint256 i = 0; i < depositors.length; i++) {
            _depositorsAllowlist.add(depositors[i]);
        }
    }

    function removeDepositorsFromAllowlist(address[] calldata depositors) external {
        _requireAdmin();
        for (uint256 i = 0; i < depositors.length; i++) {
            _depositorsAllowlist.remove(depositors[i]);
        }
    }

    function pause() external {
        _requireAtLeastOperator();
        isPaused = true;
    }

    function unpause() external {
        _requireAdmin();
        isPaused = false;
    }

    function makePrivate() external {
        _requireAdmin();
        isPrivate = true;
    }

    function makePublic() external {
        _requireAdmin();
        isPrivate = false;
    }
}
