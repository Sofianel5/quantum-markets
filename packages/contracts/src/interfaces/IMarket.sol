// SPDX-License-Identifier: All Rights Reserved
pragma solidity >=0.8.26;

import {IMarketResolver} from "./IMarketResolver.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IMarket {
    function createMarket(
        address creator,
        address marketToken,
        address resolver,
        uint256 minDeposit,
        uint256 strikePrice,
        string memory title
    ) external returns (uint256 marketId);
    function depositToMarket(address depositor, uint256 marketId, uint256 amount) external;
    function validateSwap(PoolKey calldata poolKey) external;
    function updatePostSwap(PoolKey calldata poolKey, int24 avgTick) external;
    function createProposal(uint256 marketId, bytes memory data) external;
    function resolveMarket(uint256 marketId, bool yesOrNo, bytes memory proof) external;
    function redeemRewards(uint256 marketId, address user) external;
}
