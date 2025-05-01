// SPDX-License-Identifier: All Rights Reserved
pragma solidity >=0.8.26;

import {IMarketResolver} from "./IMarketResolver.sol";

interface IMarket {
    function createMarket(address creator, address marketToken, uint256 minDeposit, string memory title)
        external
        returns (uint256 marketId);
    function createProposal(uint256 marketId, bytes memory data) external;
    function resolveMarket(uint256 marketId, bytes memory proof) external;
}
