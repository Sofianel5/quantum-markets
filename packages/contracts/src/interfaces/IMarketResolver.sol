// SPDX-License-Identifier: All Rights Reserved
pragma solidity ^0.8.26;

interface IMarketResolver {
    function verifyResolution(uint256 proposalId, bool yesOrNo, bytes memory proof) external returns (bool passed);
}
