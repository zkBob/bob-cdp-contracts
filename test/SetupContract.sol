pragma solidity ^0.8.0;

import "forge-std/Test.sol";

contract SetupContract is Test {
    bytes32 internal nextUser = keccak256(abi.encodePacked("user address"));

    uint256 public constant Q96 = 2**96;
    uint256 public constant Q48 = 2**48;

    function getNextUserAddress() public returns (address payable) {
        //bytes32 to address conversion
        address payable user = payable(address(uint160(uint256(nextUser))));
        nextUser = keccak256(abi.encodePacked(nextUser));
        return user;
    }

    //create users with 100 ether balance
    function createUsers(uint256 userNum) public returns (address payable[] memory) {
        address payable[] memory users = new address payable[](userNum);
        for (uint256 i = 0; i < userNum; i++) {
            address payable user = this.getNextUserAddress();
            vm.deal(user, 100 ether);
            users[i] = user;
        }
        return users;
    }

    //assert that two uints are approximately equal. tolerance in 1/10th of a percent
    function assertApproxEqual(
        uint256 expected,
        uint256 actual,
        uint256 tolerance
    ) public {
        uint256 leftBound = (expected * (1000 - tolerance)) / 1000;
        uint256 rightBound = (expected * (1000 + tolerance)) / 1000;
        assertTrue(leftBound <= actual && actual <= rightBound);
    }

    //move block.number forward by a given number of blocks
    function mineBlocks(uint256 numBlocks) public {
        uint256 targetBlock = block.number + numBlocks;
        vm.roll(targetBlock);
    }

    function getLength(address[] memory arr) public pure returns (uint256 len) {
        assembly {
            len := mload(add(arr, 0))
        }
    }

    function getLength(uint256[] memory arr) public pure returns (uint256 len) {
        assembly {
            len := mload(add(arr, 0))
        }
    }
}
