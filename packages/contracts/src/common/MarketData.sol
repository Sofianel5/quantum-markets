// SPDX-License-Identifier: All Rights Reserved
pragma solidity >=0.8.26;

import {IMarketResolver} from "../interfaces/IMarketResolver.sol";
import {DecisionToken, VUSD} from "../Tokens.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

enum MarketStatus {
    OPEN,
    PROPOSAL_ACCEPTED,
    TIMEOUT,
    RESOLVED_YES,
    RESOLVED_NO
}

struct MarketConfig {
    uint256 id;
    uint256 createdAt;
    uint256 minDeposit;
    uint256 deadline;
    address creator;
    address marketToken;
    address resolver;
    MarketStatus status;
    string title;
}

struct ProposalConfig {
    uint256 id;
    uint256 marketId;
    uint256 createdAt;
    address creator;
    VUSD vUSD;
    DecisionToken yesToken;
    DecisionToken noToken;
    PoolKey yesPoolKey;
    PoolKey noPoolKey;
    bytes data;
}
