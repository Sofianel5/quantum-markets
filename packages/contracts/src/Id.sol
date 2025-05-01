// SPDX-License-Identifier: All Rights Reserved
pragma solidity ^0.8.26;

contract Id {
    uint256 public id = 0;

    function getId() public returns (uint256) {
        id++;
        return id;
    }
}
