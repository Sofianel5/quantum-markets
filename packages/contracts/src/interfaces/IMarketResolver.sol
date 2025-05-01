// SPDX-License-Identifier: All Rights Reserved
pragma solidity ^0.8.26;

interface IMarketResolver {
    function verifyResolution(bool yesOrNo, bytes memory proof) external returns (bool passed);
}
