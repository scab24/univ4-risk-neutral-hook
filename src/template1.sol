// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

contract template1 is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

    uint256 public constant GAMMA_THRESHOLD = 2;
    uint256 public constant PRICE_RANGE_FACTOR = 10000;

    mapping(PoolId => int24) public lastTicks;
    mapping(PoolId => int256) public deltas;
    mapping(PoolId => int256) public gammas;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        if (isLargeSwap(params)) {
            (int128 deltaAdjustment, int128 liquidityDelta) = adjustLiquidityForDeltaGammaHedge(key, params);
            BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(deltaAdjustment, liquidityDelta);
            return (BaseHook.beforeSwap.selector, beforeSwapDelta, 0);
        } else {
            
            int256 deltaImpact = int256(params.amountSpecified) / 10;
            deltas[poolId] += deltaImpact;
        }
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
    }

    function isLargeSwap(IPoolManager.SwapParams calldata params) internal pure returns (bool) {
        return params.amountSpecified > 1000000;
    }

function adjustLiquidityForDeltaGammaHedge(PoolKey calldata key, IPoolManager.SwapParams calldata params) internal returns (int128, int128) {
    PoolId poolId = key.toId();
    int256 gammaImpact = calculateGammaImpact(params);
    int128 liquidityDelta = 0;
    if (gammaImpact != 0) {
        liquidityDelta = int128(distributeGammaHedgingLiquidity(key, gammaImpact));
        gammas[poolId] += gammaImpact;
    }
    int128 deltaAdjustment = int128(adjustDeltaHedge(key, params));
    deltas[poolId] += int256(deltaAdjustment);
    return (deltaAdjustment, liquidityDelta);
}

function calculateGammaImpact(IPoolManager.SwapParams calldata params) internal pure returns (int256) {
    return int256(params.amountSpecified) * int256(GAMMA_THRESHOLD) / 1000000;
}

    function distributeGammaHedgingLiquidity(PoolKey calldata key, int256 gammaImpact) internal returns (uint128) {
        int24 tickLower = -887272;
        int24 tickUpper = 887272;
        uint128 liquidity = uint128(uint256(abs(gammaImpact) * 1000));

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(0)
        });

        (BalanceDelta callerDelta, BalanceDelta feeDelta) = poolManager.modifyLiquidity(
            key,
            params,
            abi.encode(0)
        );


        return liquidity;
    }

    function adjustDeltaHedge(PoolKey calldata key, IPoolManager.SwapParams calldata params) internal returns (int256) {
        int256 deltaAdjustment = int256(params.amountSpecified) / 2;
        poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: !params.zeroForOne,
                amountSpecified: deltaAdjustment,
                sqrtPriceLimitX96: 0
            }),
            abi.encode(0)
        );
        return deltaAdjustment;
    }

    function getDeltaGamma(PoolId poolId) public view returns (int256, int256) {
        return (deltas[poolId], gammas[poolId]);
    }

    function abs(int256 x) internal pure returns (int256) {
        return x >= 0 ? x : -x;
    }
}