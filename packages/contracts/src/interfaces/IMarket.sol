// SPDX-License-Identifier: All Rights Reserved
pragma solidity >=0.8.26;

import {IMarketResolver} from "./IMarketResolver.sol";

interface IMarket {
    function createMarket(
        address creator,
        address marketToken,
        address resolver,
        uint256 minDeposit,
        string memory title
    ) external returns (uint256 marketId);
    function depositToMarket(address depositor, uint256 marketId, uint256 amount) external;
    function seedMarketLiquidity() external;
    function createProposal(uint256 marketId, bytes memory data) external;
    function tradeProposal(uint256 proposalId, address trader, bool yesOrNo, bool zeroForOne, int256 amountIn)
        external;
    function resolveMarket(uint256 marketId, bool yesOrNo, bytes memory proof) external;
    function redeemRewards(uint256 marketId, address user) external;
}
