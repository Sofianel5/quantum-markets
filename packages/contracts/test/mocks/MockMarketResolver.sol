// SPDX-License-Identifier: All Rights Reserved
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import "../../src/interfaces/IMarketResolver.sol";


contract MockMarketResolver is IMarketResolver{

    constructor() {}

    function verifyResolution(uint256 proposalId, bool yesOrNo, bytes memory proof)
        external
        view
        returns (bool passed)
    {
        return true;
    }
}
