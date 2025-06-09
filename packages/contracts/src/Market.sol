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
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SafeCallback} from "@uniswap/v4-periphery/src/base/SafeCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolInitializer_v4} from "@uniswap/v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {UniswapV2Library} from "@uniswap/universal-router/contracts/modules/uniswap/v2/UniswapV2Library.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {DecisionToken, TokenType, VUSD} from "./Tokens.sol";
import "forge-std/console.sol";

contract Market is IMarket, Ownable {
    using StateLibrary for IPoolManager;

    Id public id;
    IPositionManager public immutable positionManager;
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

    mapping(uint256 => MarketConfig) public markets;
    mapping(uint256 => MaxProposal) public marketMax;
    mapping(uint256 => ProposalConfig) public proposals;
    mapping(uint256 => uint256) public acceptedProposals;
    mapping(uint256 => mapping(address => uint256)) public deposits;
    mapping(uint256 => mapping(address => uint256)) public proposalDepositClaims;
    mapping(PoolId => uint256) poolToProposal;

    modifier onlyHook() {
        require(msg.sender == address(hook), "must be hook");
        _;
    }

    constructor(address admin, address _positionManager, address payable _router, address _permit2, address _swapHook)
        Ownable(admin)
    {
        id = new Id();
        positionManager = IPositionManager(_positionManager);
        router = UniversalRouter(_router);
        permit2 = IPermit2(_permit2);
        hook = MarketUtilsSwapHook(_swapHook);
        hook.initialize(address(this));
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
        uint256 deadline,
        string memory title
    ) external returns (uint256 marketId) {
        marketId = id.getId();

        markets[marketId] = MarketConfig({
            id: marketId,
            createdAt: block.timestamp,
            minDeposit: minDeposit,
            deadline: deadline,
            creator: creator,
            marketToken: marketToken,
            resolver: resolver,
            status: MarketStatus.OPEN,
            title: title
        });

        emit MarketCreated(marketId, block.timestamp, creator, title);
    }

    function createProposal(uint256 marketId, bytes memory data) external {
        MarketConfig memory marketConfig = markets[marketId];
        uint256 proposalId = id.getId();

        address depositor = msg.sender;
        uint256 totalDeposited = deposits[marketId][depositor];
        uint256 alreadyClaimed = proposalDepositClaims[proposalId][depositor];
        uint256 claimable = totalDeposited - alreadyClaimed;

        require(marketConfig.minDeposit <= claimable, "Must deposit min liquidity");
        proposalDepositClaims[proposalId][depositor] += marketConfig.minDeposit;

        // ─── split the deposit ──────────────────────────────────────────────────────
        uint256 D = marketConfig.minDeposit;
        uint256 burnTotal = (D * 2) / 3; // ⅔  → YES+NO tokens
        uint256 tokenPerPool = burnTotal / 2; // each pool gets D/3 tokens
        uint256 vusdToMint = D - burnTotal; // ⅓  → vUSD liquidity
        uint256 vusdPerPool = vusdToMint / 2; // each pool gets D/6 vUSD

        // ─── mint assets ───────────────────────────────────────────────────────────
        VUSD vUSD = new VUSD(address(this));
        vUSD.mint(address(this), vusdToMint);

        DecisionToken yesToken = new DecisionToken(TokenType.YES, address(this));
        DecisionToken noToken = new DecisionToken(TokenType.NO, address(this));

        // tokens that seed the pools stay in the contract…
        yesToken.mint(address(this), tokenPerPool);
        noToken.mint(address(this), tokenPerPool);
        // …and the user receives their trading inventory
        yesToken.mint(msg.sender, tokenPerPool);
        noToken.mint(msg.sender, tokenPerPool);

        // ─── seed the two pools ────────────────────────────────────────────────────
        PoolKey memory yesPoolKey =
            _initializePoolWithLiquidity(address(yesToken), address(vUSD), tokenPerPool, vusdPerPool);
        PoolKey memory noPoolKey =
            _initializePoolWithLiquidity(address(noToken), address(vUSD), tokenPerPool, vusdPerPool);

        poolToProposal[PoolIdLibrary.toId(yesPoolKey)] = proposalId;
        poolToProposal[PoolIdLibrary.toId(noPoolKey)] = proposalId;

        // ─── record proposal ───────────────────────────────────────────────────────
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

    function _initializePoolWithLiquidity(
        address tokenA, // decision token
        address tokenB, // vUSD
        uint256 budgetA, // decision tokens
        uint256 budgetB // vUSD
    ) internal returns (PoolKey memory) {
        (address token0, address token1) = UniswapV2Library.sortTokens(tokenA, tokenB);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: POOL_FEE,
            tickSpacing: 60,
            hooks: hook
        });

        // ─── choose a tick range that brackets the launch price ──────────────────
        int24 spacing = 60;
        int24 tickLower;
        int24 tickUpper;
        uint256 priceX18;

        if (token0 == tokenA) {
            // decision / vUSD  (price ≤ 1)
            tickLower = (TickMath.MIN_TICK / spacing) * spacing;
            tickUpper = 0;
            priceX18 = 0.5e18; // 0.5 vUSD per decision
        } else {
            // vUSD / decision  (price ≥ 1)
            tickLower = 0;
            tickUpper = (TickMath.MAX_TICK / spacing) * spacing;
            priceX18 = 2e18; // 2 decision per vUSD
        }

        // snap launch tick to grid
        uint256 priceX96 = (priceX18 * (1 << 96)) / 1e18; // Q96 price
        uint160 sqrtPrice = uint160(FixedPointMathLib.sqrt(priceX96 << 96));
        int24 launchTick = TickMath.getTickAtSqrtPrice(sqrtPrice);
        int24 gridTick =
            launchTick >= 0 ? (launchTick / spacing) * spacing : ((launchTick - (spacing - 1)) / spacing) * spacing; // round down for negatives
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(gridTick);

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        // budgets in (token0, token1) order
        uint256 amount0Max = (token0 == tokenA) ? budgetA : budgetB;
        uint256 amount1Max = (token1 == tokenA) ? budgetA : budgetB;

        uint128 liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtLower, sqrtUpper, amount0Max, amount1Max);

        // ─── multicall: init pool, then mint & settle ────────────────────────────
        bytes[] memory params = new bytes[](2);
        bytes[] memory mintParams = new bytes[](2);

        params[0] = abi.encodeWithSelector(IPoolInitializer_v4.initializePool.selector, key, sqrtPriceX96);

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        mintParams[0] =
            abi.encode(key, tickLower, tickUpper, liquidity, amount0Max, amount1Max, address(this), new bytes(0));
        mintParams[1] = abi.encode(key.currency0, key.currency1);

        params[1] = abi.encodeWithSelector(
            positionManager.modifyLiquidities.selector, abi.encode(actions, mintParams), block.timestamp + 60
        );

        _approveTokensForLiquidity(token0);
        _approveTokensForLiquidity(token1);
        positionManager.multicall(params);

        return key;
    }

    function _approveTokensForLiquidity(address token) internal {
        IERC20(token).approve(address(permit2), type(uint256).max);
        IAllowanceTransfer(address(permit2)).approve(
            token, address(positionManager), type(uint160).max, type(uint48).max
        );
    }

    function validateSwap(PoolKey calldata poolKey) external onlyHook {
        uint256 proposalId = poolToProposal[PoolIdLibrary.toId(poolKey)];
        ProposalConfig memory proposal = proposals[proposalId];
        MarketConfig memory marketConfig = markets[proposal.marketId];
        if (marketConfig.status != MarketStatus.OPEN) {
            revert ProposalNotTradable();
        }
    }

    function updatePostSwap(PoolKey calldata poolKey, int24 avgTick) external onlyHook {
        PoolId poolId = PoolIdLibrary.toId(poolKey);
        uint256 proposalId = poolToProposal[poolId];
        ProposalConfig storage proposal = proposals[proposalId];

        // only track the YES pool
        if (PoolId.unwrap(poolId) != PoolId.unwrap(PoolIdLibrary.toId(proposal.yesPoolKey))) return;

        uint256 raw = _priceFromTick(avgTick); // token1 / token0
        uint256 yesPrice = _yesPrice(poolKey, proposal, raw); // vUSD  /   YES

        // ─── record highest price so far ─────────────────────
        MaxProposal storage current = marketMax[proposal.marketId];
        if (yesPrice > current.yesPrice) {
            current.yesPrice = yesPrice;
            current.proposalId = proposalId;
        }

        // ─── graduate market if deadline crossed ───────────────
        MarketConfig storage market = markets[proposal.marketId];
        if (block.timestamp > market.deadline) graduateMarket(proposal.marketId);
    }

    function _priceFromTick(int24 tick) internal pure returns (uint256 pX18) {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick); // Q64.96
        uint256 p192 = uint256(sqrtP) * uint256(sqrtP); // Q128.192
        unchecked {
            pX18 = (p192 * 1e18) >> 192;
        } // to 1e18
    }

    function _yesPrice(
        PoolKey calldata key,
        ProposalConfig memory p,
        uint256 raw // = _priceFromTick(...)
    ) internal pure returns (uint256) {
        bool yesIsToken0 = Currency.unwrap(key.currency0) == address(p.yesToken);
        return yesIsToken0 ? raw : (1e36 / raw); // keep 18-dec
    }

    function graduateMarket(uint256 marketId) public {
        MarketConfig storage marketConfig = markets[marketId];
        require(marketConfig.deadline < block.timestamp, "Market deadline not yet reached.");
        MaxProposal storage maxProposal = marketMax[marketId];
        marketConfig.status = MarketStatus.PROPOSAL_ACCEPTED;
        acceptedProposals[marketId] = maxProposal.proposalId;
    }

    function resolveMarket(uint256 marketId, bool yesOrNo, bytes memory proof) external {
        MarketConfig storage market = markets[marketId];
        require(market.status == MarketStatus.PROPOSAL_ACCEPTED);
        uint256 proposalId = acceptedProposals[marketId];
        IMarketResolver(market.resolver).verifyResolution(proposalId, yesOrNo, proof); // Should revert if verification fails.
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
}
