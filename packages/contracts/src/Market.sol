// SPDX-License-Identifier: All Rights Reserved
pragma solidity ^0.8.26;

import {Id} from "./Id.sol";
import {MarketUtilsSwapHook} from "./MarketUtilsSwapHook.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {IMarketResolver} from "./interfaces/IMarketResolver.sol";
import {MarketStatus, MarketConfig, ProposalConfig} from "./common/MarketData.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {UniversalRouter} from "@uniswap/universal-router/contracts/UniversalRouter.sol";
import {IPoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {DecisionToken, TokenType, VUSD} from "./Tokens.sol";

contract Market is IMarket, Ownable {
    using StateLibrary for IPoolManager;

    Id public id;
    IPoolManager public immutable poolManager;
    UniversalRouter public immutable router;
    IPermit2 public immutable permit2;
    MarketUtilsSwapHook public immutable hook;

    uint24 public POOL_FEE = 3000;
    uint32 public constant TWAP_WINDOW = 15 minutes;

    event MarketCreated(uint256 indexed marketId, uint256 createdAt, address creator, string title);
    event ProposalCreated(uint256 indexed marketId, uint256 indexed proposalId, uint256 createdAt, address creator);
    event MarketSettled(uint256 indexed marketId, bool passed);

    error MarketClosed();
    error ProposalNotTradable();
    error MarketNotSettled();

    struct MaxProposal {
        uint256 yesPrice;
        uint256 proposalId;
    }

    mapping(uint256 => MarketConfig) markets;
    mapping(uint256 => MaxProposal) marketMax;
    mapping(uint256 => ProposalConfig) proposals;
    mapping(uint256 => uint256) acceptedProposals;
    mapping(uint256 => mapping(address => uint256)) deposits;
    mapping(uint256 => mapping(address => uint256)) proposalDepositClaims;

    constructor(address admin, address payable _router, address _poolManager, address _permit2) Ownable(admin) {
        router = UniversalRouter(_router);
        poolManager = IPoolManager(_poolManager);
        permit2 = IPermit2(_permit2);
        hook = new MarketUtilsSwapHook(poolManager, address(this));
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
        deposits[marketId][depositor] += amount;
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
        ProposalConfig memory config = proposals[proposalId];
        config.yesToken.burnFrom(msg.sender, amount);
        config.noToken.burnFrom(msg.sender, amount);
        config.vUSD.transferFrom(address(this), msg.sender, amount);
    }

    function createMarket(
        address creator,
        address marketToken,
        address resolver,
        uint256 minDeposit,
        uint256 strikePrice,
        string memory title
    ) external returns (uint256 marketId) {
        marketId = id.getId();

        markets[marketId] = MarketConfig({
            id: marketId,
            createdAt: block.timestamp,
            minDeposit: minDeposit,
            strikePrice: strikePrice,
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

        address depositor = msg.sender;
        uint256 totalDeposited = deposits[marketId][depositor];
        uint256 alreadyClaimed = proposalDepositClaims[proposalId][depositor];
        uint256 claimable = totalDeposited - alreadyClaimed;

        require(claimable < marketConfig.minDeposit, "Must deposit min liquidity");
        vUSD.mint(address(this), marketConfig.minDeposit);
        proposalDepositClaims[proposalId][depositor] += marketConfig.minDeposit;

        DecisionToken yesToken = new DecisionToken(TokenType.YES, address(this));
        DecisionToken noToken = new DecisionToken(TokenType.NO, address(this));

        mintYesNo(marketId, marketConfig.minDeposit / 2);

        PoolKey memory yesPoolKey = PoolKey({
            currency0: Currency.wrap(address(yesToken)),
            currency1: Currency.wrap(address(vUSD)),
            fee: POOL_FEE,
            tickSpacing: 60,
            hooks: hook
        });
        poolManager.initialize(
            yesPoolKey,
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK + 1) // ≈ 0 price
        );
        PoolKey memory noPoolKey = PoolKey({
            currency0: Currency.wrap(address(noToken)),
            currency1: Currency.wrap(address(vUSD)),
            fee: POOL_FEE,
            tickSpacing: 60,
            hooks: hook
        });
        poolManager.initialize(
            noPoolKey,
            TickMath.getSqrtPriceAtTick(0) // 1:1 price
        );

        poolManager.modifyLiquidity(
            yesPoolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.MIN_TICK,
                tickUpper: TickMath.MAX_TICK,
                liquidityDelta: int256(marketConfig.minDeposit / 4),
                salt: 0
            }),
            ""
        );

        poolManager.modifyLiquidity(
            noPoolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.MIN_TICK,
                tickUpper: TickMath.MAX_TICK,
                liquidityDelta: int256((marketConfig.minDeposit * 3) / 4),
                salt: 0
            }),
            ""
        );

        proposals[proposalId] = ProposalConfig({
            id: proposalId,
            marketId: marketId,
            createdAt: block.timestamp,
            creator: msg.sender,
            vUSD: vUSD,
            yesToken: yesToken,
            noToken: noToken,
            yesPoolKey: yesPoolKey,
            noPoolKey: noPoolKey,
            data: data
        });

        emit ProposalCreated(marketId, proposalId, block.timestamp, msg.sender);
    }

    function tradeProposal(uint256 proposalId, bool yesThenNo, bool zeroForOne, uint256 amountIn, uint256 amountOutMin)
        external
    {
        ProposalConfig memory proposal = proposals[proposalId];
        MarketConfig memory marketConfig = markets[proposal.marketId];
        PoolKey memory key = yesThenNo ? proposal.yesPoolKey : proposal.noPoolKey;
        if (
            marketConfig.status != MarketStatus.OPEN
                || (
                    marketConfig.status == MarketStatus.PROPOSAL_ACCEPTED
                        && acceptedProposals[proposal.marketId] == proposalId
                )
        ) {
            revert ProposalNotTradable();
        }

        _routerSwap(msg.sender, key, zeroForOne, amountIn, amountOutMin);

        if (yesThenNo && zeroForOne) {
            uint256 yesPrice = _twapX18(key);
            MaxProposal memory currentMax = marketMax[proposal.marketId];
            if (yesPrice > currentMax.yesPrice && currentMax.proposalId != proposalId) {
                marketMax[proposal.marketId] = MaxProposal({yesPrice: yesPrice, proposalId: proposalId});
            }
            if (yesPrice > marketConfig.strikePrice) {
                _graduateMarket(proposalId);
            }
        }
    }

    function _routerSwap(address user, PoolKey memory key, bool zeroForOne, uint256 amountIn, uint256 amountOutMin)
        internal
    {
        Currency inCur = zeroForOne ? key.currency0 : key.currency1;
        IERC20(Currency.unwrap(inCur)).transferFrom(user, address(this), amountIn);
        IERC20(Currency.unwrap(inCur)).approve(address(permit2), amountIn);
        require(amountIn <= type(uint160).max, "amount too large");
        permit2.approve(
            Currency.unwrap(inCur),
            address(router),
            uint160(amountIn),
            uint48(block.timestamp)
        );

        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: uint128(amountIn),
                amountOutMinimum: uint128(amountOutMin),
                hookData: ""
            })
        );
        params[1] = abi.encode(inCur, amountIn); // SETTLE_ALL
        params[2] = abi.encode(zeroForOne ? key.currency1 : key.currency0, amountOutMin); // TAKE_ALL
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        bytes memory command = abi.encodePacked(uint8(Commands.V4_SWAP));
        router.execute(command, inputs, block.timestamp);
    }

    function _priceFromTick(int24 tick) internal pure returns (uint256) {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        uint256 p192  = uint256(sqrtP) * uint256(sqrtP);
        return (p192 * 1e18) >> 192;
    }

    function _twapX18(PoolKey memory key) internal view returns (uint256) {
        int24 avgTick = hook.consult(key, TWAP_WINDOW);
        return _priceFromTick(avgTick);
    }

    function _graduateMarket(uint256 proposalId) internal {
        ProposalConfig memory proposalConfig = proposals[proposalId];
        MarketConfig storage marketConfig = markets[proposalConfig.marketId];
        marketConfig.status = MarketStatus.PROPOSAL_ACCEPTED;
        acceptedProposals[proposalConfig.marketId] = proposalId;
    }

    function resolveMarket(uint256 marketId, bool yesOrNo, bytes memory proof) external {
        MarketConfig storage market = markets[marketId];
        require(market.status == MarketStatus.PROPOSAL_ACCEPTED);
        IMarketResolver(market.resolver).verifyResolution(yesOrNo, proof); // Should revert if verification fails.
        if (yesOrNo) {
            market.status = MarketStatus.RESOLVED_YES;
        } else {
            market.status = MarketStatus.RESOLVED_NO;
        }

        emit MarketSettled(marketId, yesOrNo);
    }

    function redeemRewards(uint256 marketId, address user) external {
        MarketConfig memory market = markets[marketId];
        uint256 winningProposalId = acceptedProposals[marketId];
        ProposalConfig memory proposal = proposals[winningProposalId];
        uint256 tradingRewards = proposal.vUSD.balanceOf(user);
        proposal.vUSD.burnFrom(user, tradingRewards);
        if (market.status == MarketStatus.RESOLVED_YES) {
            uint256 tokenBalance = proposal.yesToken.balanceOf(user);
            proposal.yesToken.burnFrom(user, tokenBalance);
            tradingRewards += tokenBalance;
        } else if (market.status == MarketStatus.RESOLVED_NO) {
            uint256 tokenBalance = proposal.noToken.balanceOf(user);
            proposal.noToken.burnFrom(user, tokenBalance);
            tradingRewards += tokenBalance;
        } else {
            revert MarketNotSettled();
        }

        ERC20(market.marketToken).transfer(user, tradingRewards);
    }

    function acceptMarket(uint256 marketId) internal {}
}
