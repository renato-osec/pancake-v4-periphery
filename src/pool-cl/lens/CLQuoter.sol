// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {ICLQuoter} from "../interfaces/ICLQuoter.sol";
import {PoolTicksCounter} from "../libraries/PoolTicksCounter.sol";
import {PathKey, PathKeyLibrary} from "../../libraries/PathKey.sol";
import {Quoter} from "../../base/Quoter.sol";

contract CLQuoter is Quoter, ICLQuoter {
    using PathKeyLibrary for PathKey;

    ICLPoolManager public immutable poolManager;
    uint256 private constant CL_MINIMUM_VALID_RESPONSE_LENGTH = 192;

    /// @dev min valid reason is 6-words long (192 bytes)
    /// @dev int128[2] includes 32 bytes for offset, 32 bytes for length, and 32 bytes for each element
    /// @dev Plus sqrtPriceX96After padded to 32 bytes and initializedTicksLoaded padded to 32 bytes
    constructor(address _poolManager) Quoter(_poolManager, CL_MINIMUM_VALID_RESPONSE_LENGTH) {
        poolManager = ICLPoolManager(_poolManager);
    }

    /// @inheritdoc ICLQuoter
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        override
        returns (int128[] memory deltaAmounts, uint160 sqrtPriceX96After, uint32 initializedTicksLoaded)
    {
        try vault.lock(abi.encodeCall(this._quoteExactInputSingle, (params))) {}
        catch (bytes memory reason) {
            return _handleRevertSingle(reason);
        }
    }

    /// @inheritdoc ICLQuoter
    function quoteExactInput(QuoteExactParams memory params)
        external
        override
        returns (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        )
    {
        try vault.lock(abi.encodeCall(this._quoteExactInput, (params))) {}
        catch (bytes memory reason) {
            return _handleRevert(reason);
        }
    }

    /// @inheritdoc ICLQuoter
    function quoteExactOutputSingle(QuoteExactSingleParams memory params)
        external
        override
        returns (int128[] memory deltaAmounts, uint160 sqrtPriceX96After, uint32 initializedTicksLoaded)
    {
        try vault.lock(abi.encodeCall(this._quoteExactOutputSingle, (params))) {}
        catch (bytes memory reason) {
            if (params.sqrtPriceLimitX96 == 0) delete amountOutCached;
            return _handleRevertSingle(reason);
        }
    }

    /// @inheritdoc ICLQuoter
    function quoteExactOutput(QuoteExactParams memory params)
        external
        override
        returns (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        )
    {
        try vault.lock(abi.encodeCall(this._quoteExactOutput, (params))) {}
        catch (bytes memory reason) {
            return _handleRevert(reason);
        }
    }

    /// @dev parse revert bytes from a single-pool quote
    function _handleRevertSingle(bytes memory reason)
        private
        view
        returns (int128[] memory deltaAmounts, uint160 sqrtPriceX96After, uint32 initializedTicksLoaded)
    {
        reason = validateRevertReason(reason);
        (deltaAmounts, sqrtPriceX96After, initializedTicksLoaded) = abi.decode(reason, (int128[], uint160, uint32));
    }

    /// @dev parse revert bytes from a potentially multi-hop quote and return the delta amounts, sqrtPriceX96After, and initializedTicksLoaded
    function _handleRevert(bytes memory reason)
        private
        view
        returns (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        )
    {
        reason = validateRevertReason(reason);
        (deltaAmounts, sqrtPriceX96AfterList, initializedTicksLoadedList) =
            abi.decode(reason, (int128[], uint160[], uint32[]));
    }

    /// @dev quote an ExactInput swap along a path of tokens, then revert with the result
    function _quoteExactInput(QuoteExactParams memory params) public override selfOnly returns (bytes memory) {
        uint256 pathLength = params.path.length;

        QuoteResult memory result = QuoteResult({
            deltaAmounts: new int128[](pathLength + 1),
            sqrtPriceX96AfterList: new uint160[](pathLength),
            initializedTicksLoadedList: new uint32[](pathLength)
        });
        QuoteCache memory cache;

        for (uint256 i = 0; i < pathLength; i++) {
            (PoolKey memory poolKey, bool zeroForOne) =
                params.path[i].getPoolAndSwapDirection(i == 0 ? params.exactCurrency : cache.prevCurrency);
            (, cache.tickBefore,,) = poolManager.getSlot0(poolKey.toId());

            (cache.curDeltas, cache.sqrtPriceX96After, cache.tickAfter) = _swap(
                poolKey,
                zeroForOne,
                -int256(int128(i == 0 ? params.exactAmount : cache.prevAmount)),
                0,
                params.path[i].hookData
            );

            (cache.deltaIn, cache.deltaOut) = zeroForOne
                ? (cache.curDeltas.amount0(), cache.curDeltas.amount1())
                : (cache.curDeltas.amount1(), cache.curDeltas.amount0());
            result.deltaAmounts[i] += cache.deltaIn;
            result.deltaAmounts[i + 1] += cache.deltaOut;

            cache.prevAmount = zeroForOne ? uint128(cache.curDeltas.amount1()) : uint128(cache.curDeltas.amount0());
            cache.prevCurrency = params.path[i].intermediateCurrency;
            result.sqrtPriceX96AfterList[i] = cache.sqrtPriceX96After;
            result.initializedTicksLoadedList[i] =
                PoolTicksCounter.countInitializedTicksLoaded(poolManager, poolKey, cache.tickBefore, cache.tickAfter);
        }
        bytes memory r =
            abi.encode(result.deltaAmounts, result.sqrtPriceX96AfterList, result.initializedTicksLoadedList);
        assembly ("memory-safe") {
            revert(add(0x20, r), mload(r))
        }
    }

    /// @dev quote an ExactInput swap on a pool, then revert with the result
    function _quoteExactInputSingle(QuoteExactSingleParams memory params)
        public
        override
        selfOnly
        returns (bytes memory)
    {
        (, int24 tickBefore,,) = poolManager.getSlot0(params.poolKey.toId());

        (BalanceDelta deltas, uint160 sqrtPriceX96After, int24 tickAfter) = _swap(
            params.poolKey,
            params.zeroForOne,
            -int256(int128(params.exactAmount)),
            params.sqrtPriceLimitX96,
            params.hookData
        );

        int128[] memory deltaAmounts = new int128[](2);

        deltaAmounts[0] = deltas.amount0();
        deltaAmounts[1] = deltas.amount1();

        uint32 initializedTicksLoaded =
            PoolTicksCounter.countInitializedTicksLoaded(poolManager, params.poolKey, tickBefore, tickAfter);
        bytes memory result = abi.encode(deltaAmounts, sqrtPriceX96After, initializedTicksLoaded);
        assembly ("memory-safe") {
            revert(add(0x20, result), mload(result))
        }
    }

    /// @dev quote an ExactOutput swap along a path of tokens, then revert with the result
    function _quoteExactOutput(QuoteExactParams memory params) public override selfOnly returns (bytes memory) {
        uint256 pathLength = params.path.length;

        QuoteResult memory result = QuoteResult({
            deltaAmounts: new int128[](pathLength + 1),
            sqrtPriceX96AfterList: new uint160[](pathLength),
            initializedTicksLoadedList: new uint32[](pathLength)
        });
        QuoteCache memory cache;
        uint128 curAmountOut;

        for (uint256 i = pathLength; i > 0; i--) {
            curAmountOut = i == pathLength ? params.exactAmount : cache.prevAmount;
            amountOutCached = curAmountOut;

            (PoolKey memory poolKey, bool oneForZero) = PathKeyLibrary.getPoolAndSwapDirection(
                params.path[i - 1], i == pathLength ? params.exactCurrency : cache.prevCurrency
            );

            (, cache.tickBefore,,) = poolManager.getSlot0(poolKey.toId());

            (cache.curDeltas, cache.sqrtPriceX96After, cache.tickAfter) =
                _swap(poolKey, !oneForZero, int256(uint256(curAmountOut)), 0, params.path[i - 1].hookData);

            // always clear because sqrtPriceLimitX96 is set to 0 always
            delete amountOutCached;
            (cache.deltaIn, cache.deltaOut) = !oneForZero
                ? (cache.curDeltas.amount0(), cache.curDeltas.amount1())
                : (cache.curDeltas.amount1(), cache.curDeltas.amount0());
            result.deltaAmounts[i - 1] += cache.deltaIn;
            result.deltaAmounts[i] += cache.deltaOut;

            cache.prevAmount = !oneForZero ? uint128(-cache.curDeltas.amount0()) : uint128(-cache.curDeltas.amount1());
            cache.prevCurrency = params.path[i - 1].intermediateCurrency;
            result.sqrtPriceX96AfterList[i - 1] = cache.sqrtPriceX96After;
            result.initializedTicksLoadedList[i - 1] =
                PoolTicksCounter.countInitializedTicksLoaded(poolManager, poolKey, cache.tickBefore, cache.tickAfter);
        }
        bytes memory r =
            abi.encode(result.deltaAmounts, result.sqrtPriceX96AfterList, result.initializedTicksLoadedList);
        assembly ("memory-safe") {
            revert(add(0x20, r), mload(r))
        }
    }

    /// @dev quote an ExactOutput swap on a pool, then revert with the result
    function _quoteExactOutputSingle(QuoteExactSingleParams memory params)
        public
        override
        selfOnly
        returns (bytes memory)
    {
        // if no price limit has been specified, cache the output amount for comparison inside the _swap function
        if (params.sqrtPriceLimitX96 == 0) amountOutCached = params.exactAmount;

        (, int24 tickBefore,,) = poolManager.getSlot0(params.poolKey.toId());
        (BalanceDelta deltas, uint160 sqrtPriceX96After, int24 tickAfter) = _swap(
            params.poolKey,
            params.zeroForOne,
            int256(uint256(params.exactAmount)),
            params.sqrtPriceLimitX96,
            params.hookData
        );

        if (amountOutCached != 0) delete amountOutCached;
        int128[] memory deltaAmounts = new int128[](2);

        deltaAmounts[0] = deltas.amount0();
        deltaAmounts[1] = deltas.amount1();

        uint32 initializedTicksLoaded =
            PoolTicksCounter.countInitializedTicksLoaded(poolManager, params.poolKey, tickBefore, tickAfter);
        bytes memory result = abi.encode(deltaAmounts, sqrtPriceX96After, initializedTicksLoaded);
        assembly ("memory-safe") {
            revert(add(0x20, result), mload(result))
        }
    }

    /// @dev Execute a swap and return the amounts delta, as well as relevant pool state
    /// @notice if amountSpecified < 0, the swap is exactInput, otherwise exactOutput
    function _swap(
        PoolKey memory poolKey,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes memory hookData
    ) private returns (BalanceDelta deltas, uint160 sqrtPriceX96After, int24 tickAfter) {
        deltas = poolManager.swap(
            poolKey,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: _sqrtPriceLimitOrDefault(sqrtPriceLimitX96, zeroForOne)
            }),
            hookData
        );
        // only exactOut case
        if (amountOutCached != 0 && amountOutCached != uint128(zeroForOne ? deltas.amount1() : deltas.amount0())) {
            revert InsufficientAmountOut();
        }
        (sqrtPriceX96After, tickAfter,,) = poolManager.getSlot0(poolKey.toId());
    }

    /// @dev return either the sqrtPriceLimit from user input, or the max/min value possible depending on trade direction
    function _sqrtPriceLimitOrDefault(uint160 sqrtPriceLimitX96, bool zeroForOne) private pure returns (uint160) {
        return sqrtPriceLimitX96 == 0
            ? zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            : sqrtPriceLimitX96;
    }
}
