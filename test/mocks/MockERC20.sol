// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mintable ERC-20 for tests.
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Asset", "mASSET") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
