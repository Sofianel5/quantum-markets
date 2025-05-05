// SPDX‑License‑Identifier: GPL‑3.0‑or‑later
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract OnlyMarketSwapHook is BaseHook {
    address public immutable market;

    constructor(IPoolManager pm, address _market) BaseHook(pm) {
        market = _market;
    }

    /* advertise the callbacks we implement */
    function getHookPermissions() public pure override returns (uint8) {
        return Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
    }

    /* gate every swap */
    function beforeSwap(address sender, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        returns (bytes4)
    {
        if (sender != market) revert("not-market");
        return OnlyMarketSwapHook.beforeSwap.selector;
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata, int128, int128)
        external
        override
        returns (bytes4)
    {
        return OnlyMarketSwapHook.afterSwap.selector;
    }
}
