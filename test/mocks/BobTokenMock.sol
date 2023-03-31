// SPDX-License-Identifier: CC0-1.0

pragma solidity ^0.8.0;

import {BobToken} from "@zkbob/BobToken.sol";

contract BobTokenMock is BobToken {
    constructor() BobToken(address(this)) {
        _transferOwnership(msg.sender);
    }
}
