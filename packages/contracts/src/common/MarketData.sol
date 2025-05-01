// SPDX-License-Identifier: All Rights Reserved
pragma solidity >=0.8.26;

import {IMarketResolver} from "../interfaces/IMarketResolver.sol";
import {DecisionToken, WUSDC} from "../Tokens.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

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
    uint256 strikePrice;
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
    IUniswapV3Pool yesPool;
    IUniswapV3Pool noPool;
    bytes data;
}
