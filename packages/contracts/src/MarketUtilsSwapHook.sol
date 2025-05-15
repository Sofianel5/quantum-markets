// SPDX-License-Identifier: All Rights Reserved
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "forge-std/console.sol";

interface IMsgSender {
    function msgSender() external view returns (address);
}

contract MarketUtilsSwapHook is BaseHook, Ownable {
    using StateLibrary for IPoolManager;

    address public market;
    bool private initialized;

    struct Obs {
        uint32 time;
        int56 tickCumulative;
        int24 lastTick;
    }

    mapping(PoolId poolId => Obs) public lastObs;
    mapping(address swapRouter => bool approved) public verifiedRouters;

    constructor(IPoolManager pm) BaseHook(pm) Ownable(msg.sender) {}

    function initialize(address _market) external {
        require(!initialized, "Contract instance has already been initialized");
        initialized = true;
        market = _market;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(address sender, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!initialized) revert("not-initialized");
        if (verifiedRouters[sender]) {
            address swapper = IMsgSender(sender).msgSender();
            console.log("Swap initiated by account:", swapper);
            if (swapper != market) revert("not-market");
        } else {
            revert("invalid-router");
        }
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = PoolIdLibrary.toId(key);
        Obs storage o = lastObs[id];
        (, int24 tick,,) = poolManager.getSlot0(id);

        uint32 now32 = uint32(block.timestamp);
        if (o.time != 0) {
            o.tickCumulative += int56(int24(tick)) * int56(uint56(now32 - o.time));
        }
        o.time = now32;
        o.lastTick = tick;
        return (BaseHook.afterSwap.selector, 0);
    }

    function consult(PoolKey calldata key, uint32 secondsAgo) external view returns (int24 avgTick) {
        require(secondsAgo != 0, "secondsAgo=0");
        PoolId id = PoolIdLibrary.toId(key);

        Obs storage o = lastObs[id];
        require(o.time != 0, "no obs yet");

        uint32 dtNow = uint32(block.timestamp) - o.time;
        int56 tickCumulativeNow = o.tickCumulative + int56(o.lastTick) * int56(uint56(dtNow));

        require(secondsAgo <= dtNow, "window > stored span");

        int56 tickCumulativeAgo = tickCumulativeNow - int56(o.lastTick) * int56(uint56(secondsAgo));

        avgTick = int24((tickCumulativeNow - tickCumulativeAgo) / int56(uint56(secondsAgo)));
    }

    function addRouter(address _router) external onlyOwner {
        verifiedRouters[_router] = true;
        console.log("Router added:", _router);
    }

    function removeRouter(address _router) external onlyOwner {
        verifiedRouters[_router] = false;
        console.log("Router removed:", _router);
    }

    function isVerifiedRouter(address _router) external view returns (bool) {
        return verifiedRouters[_router];
    }
}
