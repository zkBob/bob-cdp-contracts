// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@zkbob/interfaces/IBurnableERC20.sol";
import "@zkbob/interfaces/IMintableERC20.sol";

interface IMinter is IMintableERC20, IBurnableERC20 {}
