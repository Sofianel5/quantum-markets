// SPDX-License-Identifier: All Rights Reserved
pragma solidity ^0.8.26;

import {Id} from "./Id.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {IMarketResolver} from "./interfaces/IMarketResolver.sol";
import {MarketStatus, MarketConfig, ProposalConfig} from "./common/MarketData.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {DecisionToken, TokenType, WUSDC} from "./Tokens.sol";

contract Market is IMarket, Ownable {
    Id public id;
    IUniswapV3Factory public uniV3Factory;
    INonfungiblePositionManager public nonfungiblePositionManager;

    uint24 public POOL_FEE = 3000;

    event MarketCreated(uint256 indexed marketId, uint256 createdAt, address creator, string title);
    event ProposalCreated(uint256 indexed marketId, uint256 indexed proposalId, uint256 createdAt, address creator);
    event MarketSettled(uint256 indexed marketId, bool passed);

    error MarketClosed();
    error ProposalNotTradable();

    struct MaxProposal {
        int256 yesPrice;
        uint256 proposalId;
    }

    mapping(uint256 => MarketConfig) markets;
    mapping(uint256 => MaxProposal) marketMax;
    mapping(uint256 => ProposalConfig) proposals;
    mapping(uint256 => uint256) acceptedProposals;
    mapping(uint256 => mapping(address => uint256)) deposits;
    mapping(uint256 => mapping(address => uint256)) proposalDepositClaims;
    mapping(uint256 => mapping(address => bool)) claims;

    constructor(address admin, IUniswapV3Factory _factory, INonfungiblePositionManager _positionManager)
        Ownable(admin)
    {
        uniV3Factory = _factory;
        nonfungiblePositionManager = _positionManager;
    }

    function changeFee(uint24 newFee) external onlyOwner {
        POOL_FEE = newFee;
    }

    function depositToMarket(address depositor, uint256 marketId, uint256 amount) external {
        MarketConfig memory config = markets[marketId];
        if (
            config.status == MarketStatus.RESOLVED_YES || config.status == MarketStatus.RESOLVED_NO
                || config.status == MarketStatus.TIMEOUT
        ) {
            revert MarketClosed();
        }
        ERC20(config.marketToken).transferFrom(depositor, address(this), amount);
        depsoits[marketId] += amount;
    }

    function claimVirtualTokenForProposal(address depositor, uint256 proposalId) external {
        ProposalConfig memory proposalConfig = proposals[proposalId];
        uint256 marketId = proposalConfig.marketId;
        uint256 totalDeposited = deposits[marketId][depositor];
        uint256 alreadyClaimed = proposalDepositClaims[proposalId][depositor];
        uint256 claimable = totalDeposited - alreadyClaimed;

        require(claimable > 0, "Nothing to claim");

        proposalDepositClaims[proposalId][depositor] += claimable;
        proposalConfig.vUSD.mint(depositor, claimable);
    }

    function mintYesNo(uint256 proposalId, uint256 amount) public {
        ProposalConfig memory config = proposals[proposalId];
        config.vUSD.transferFrom(msg.sender, address(this), amount);
        config.yesToken.mint(msg.sender, amount);
        config.noToken.mint(msg.sender, amount);
    }

    function redeemYesNo(uint256 proposalId, uint256 amount) external {
        ProposalConfig memory config = markets[marketId];
        config.yesToken.burnFrom(msg.sender, amount);
        config.noToken.burnFrom(msg.sender, amount);
        config.vUSD.transferFrom(address(this), msg.sender, amount);
    }

    function createMarket(
        address creator,
        address marketToken,
        address resolver,
        uint256 minDeposit,
        string memory title
    ) external returns (uint256 marketId) {
        uint256 marketId = id.getId();

        markets[marketId] = MarketConfig({
            id: marketId,
            createdAt: block.timestamp,
            minDeposit: minDeposit,
            creator: creator,
            marketToken: marketToken,
            resolver: resolver,
            status: MarketStatus.OPEN,
            title: title
        });

        emit MarketCreated(marketId, block.timestamp, creator, title);
    }

    function seedMarketLiquidity() external {}

    function createProposal(uint256 marketId, bytes memory data) external {
        MarketConfig memory marketConfig = markets[marketId];

        uint256 proposalId = id.getId();

        VUSD vUSD = new VUSD(address(this));

        uint256 totalDeposited = deposits[marketId][depositor];
        uint256 alreadyClaimed = proposalDepositClaims[proposalId][depositor];
        uint256 claimable = totalDeposited - alreadyClaimed;

        require(claimable < marketConfig.minDeposit, "Must deposit min liquidity");
        vUSD.mint(address(this), marketConfig.minDeposit);
        proposalDepositClaims[proposalId][depositor] += marketConfig.minDeposit;

        DecisionToken yesToken = new DecisionToken(TokenType.YES, address(this));
        DecisionToken noToken = new DecisionToken(TokenType.NO, address(this));

        mintYesNo(marketId, marketConfig.minDeposit / 2);

        IUniswapV3Pool yesPool = IUniswapV3Pool(uniV3Factory.createPool(address(yesToken), address(vUSD), POOL_FEE));
        IUniswapV3Pool noPool = IUniswapV3Pool(uniV3Factory.createPool(address(noToken), address(vUSD), POOL_FEE));

        yesPool.initialize(TickMath.getSqrtRatioAtTick(0));
        noPool.initialize(TickMath.getSqrtRatioAtTick(0));

        nonfungiblePositionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(yesToken),
                token1: address(vUSD),
                fee: POOL_FEE,
                tickLower: TickMath.MIN_TICK,
                tickUpper: TickMath.MAX_TICK,
                amount0Desired: marketConfig.minDeposit / 4,
                amount1Desired: marketConfig.minDeposit / 4,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp + 15
            })
        );
        nonfungiblePositionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(noToken),
                token1: address(vUSD),
                fee: POOL_FEE,
                tickLower: TickMath.MIN_TICK,
                tickUpper: TickMath.MAX_TICK,
                amount0Desired: marketConfig.minDeposit - marketConfig.minDeposit / 4,
                amount1Desired: marketConfig.minDeposit - marketConfig.minDeposit / 4,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp + 15
            })
        );

        proposals[proposalId] = ProposalConfig({
            id: proposalId,
            createdAt: block.timestamp,
            creator: msg.sender,
            vUSD: vUSD,
            yesToken: yesToken,
            noToken: noToken,
            yesPool: yesPool,
            noPool: noPool,
            data: data
        });

        emit ProposalCreated(marketId, proposalId, block.timestamp, msg.sender);
    }

    function tradeProposal(uint256 proposalId, address trader, bool yesOrNo, bool zeroForOne, int256 amountIn)
        external
    {
        ProposalConfig memory proposal = proposals[proposalId];
        MarketConfig memory marketConfig = markets[proposal.marketId];
        if (
            marketConfig.status != MarketStatus.OPEN
                || (
                    marketConfig.status == MarketStatus.PROPOSAL_ACCEPTED
                        && acceptedProposals[proposal.marketId] == proposalId
                )
        ) {
            revert ProposalNotTradable();
        }

        IERC20 inputToken = zeroForOne ? IERC20(proposal.yesPool.token0()) : IERC20(proposal.yesPool.token1());

        inputToken.transferFrom(trader, address(this), uint256(amountIn));

        inputToken.approve(address(yesOrNo ? proposal.yesPool : proposal.noPool), uint256(amountIn));

        (int256 amount0, int256 amount1) = yesOrNo
            ? proposal.yesPool.swap(trader, zeroForOne, amountIn, 0, "")
            : proposal.noPool.swap(trader, zeroForOne, amountIn, 0, "");

        if (yesOrNo && zeroForOne && amount0 != 0) {
            int256 yesPrice = (amount1 * 1e18) / amount0;
            MaxProposal memory currentMax = marketMax[proposal.marketId];
            if (yesPrice > currentMax.yesPrice && currentMax.proposalId != proposalId) {
                marketMax[proposal.marketId] = MaxProposal({yesPrice: yesPrice, proposalId: proposalId});
            }
            if (yesPrice > marketConfig.strikePrice) {
                graduateMarket(proposalId);
            }
        }
    }

    function graduateMarket(uint256 proposalId) internal {
        ProposalConfig memory proposalConfig = proposals[proposalId];
        MarketConfig storage marketConfig = markets[proposalConfig.marketId];
        marketConfig.status = MarketStatus.PROPOSAL_ACCEPTED;
        acceptedProposals[proposalConfig.marketId] = proposalId;
    }

    function resolveMarket(uint256 marketId, bool yesOrNo, bytes memory proof) external {
        MarketConfig storage market = markets[marketId];
        require(market.status == MarketStatus.PROPOSAL_ACCEPTED);
        IMarketResolver(market.resolver).verifyResolution(yesOrNo, proof);
        if (yesOrNo) {
            market.status = MarketStatus.RESOLVED_YES;
        } else {
            market.status = MarketStatus.RESOLVED_NO;
        }
        account.rewardsUsed += account.successReward;
        market.yesPool.collect(owner(), TickMath.MIN_TICK, TickMath.TICK_MAX, type(uint128).max, type(uint128).max);
        market.noPool.collect(owner(), TickMath.MIN_TICK, TickMath.TICK_MAX, type(uint128).max, type(uint128).max);

        emit MarketSettled(marketId, passed);
    }

    function redeemRewards(uint256 proposalId, address user) external {
        ProposalConfig memory proposal = proposals[proposalId];
        MarketConfig memory market = markets[proposal.marketId];
        uint256 tradingRewards;
        if (market.status == MarketStatus.RESOLVED_YES) {
            tradingRewards = market.yesToken.balanceOf(user);
        } else if (market.status == MarketStatus.RESOLVED_NO) {
            tradingRewards = market.noToken.balanceOf(user);
        }

        claims[marketId][user] = true;
        ERC20(account.marketToken).transfer(user, tradingRewards);
    }

    function acceptMarket(uint256 marketId) internal {}
}
