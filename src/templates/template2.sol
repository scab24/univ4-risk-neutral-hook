// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.0;

// import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
// import {Hooks} from "v4-core/libraries/Hooks.sol";
// import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
// import {PoolKey} from "v4-core/types/PoolKey.sol";
// import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
// import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
// import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
// import {TickMath} from "v4-core/libraries/TickMath.sol";
// import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
// import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

// /**
//  * @title DeltaGammaHedgingHook
//  * @dev Implements Delta-Gamma hedging strategies for Uniswap V4 pools
//  * @notice This contract aims to mitigate impermanent loss through dynamic hedging
//  */
// contract DeltaGammaHedgingHook is BaseHook {
//     using PoolIdLibrary for PoolKey;
//     using CurrencyLibrary for Currency;
//     using FixedPointMathLib for uint256;

//     using PoolIdLibrary for PoolKey;
//     using CurrencyLibrary for Currency;
//     using FixedPointMathLib for uint256;

//     // Thresholds and factors for hedging calculations
//     uint256 public constant GAMMA_THRESHOLD = 2;
//     uint256 public constant PRICE_RANGE_FACTOR = 10000;

//     // Mappings to store metrics per pool
//     mapping(PoolId => int24) public lastTicks;
//     mapping(PoolId => int256) public deltas;
//     mapping(PoolId => int256) public gammas;

//     /**
//      * @dev Constructor for DeltaGammaHedgingHook
//      * @param _poolManager Address of the Uniswap V4 pool manager
//      */
//     constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

//     /**
//      * @dev Defines the permissions for this hook
//      * @return Hooks.Permissions struct with allowed hook points
//      */
//     function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
//         return Hooks.Permissions({
//             beforeInitialize: true,
//             afterInitialize: false,
//             beforeAddLiquidity: false,
//             afterAddLiquidity: false,
//             beforeRemoveLiquidity: false,
//             afterRemoveLiquidity: false,
//             beforeSwap: true,
//             afterSwap: true,
//             beforeDonate: false,
//             afterDonate: false,
//             beforeSwapReturnDelta: true,
//             afterSwapReturnDelta: true,
//             afterAddLiquidityReturnDelta: false,
//             afterRemoveLiquidityReturnDelta: false
//         });
//     }

//     /**
//      * @dev Hook called before pool initialization
//      * @param sender Address initiating the pool
//      * @param key Pool key
//      * @param sqrtPriceX96 Initial sqrt price
//      * @param hookData Additional data for the hook
//      * @return bytes4 Function selector
//      */
//     function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, bytes calldata hookData) external override returns (bytes4) {
//         require(key.fee >= 10000, "Fee must be at least 1%");
//         return BaseHook.beforeInitialize.selector;
//     }

//     /**
//      * @dev Hook called before a swap
//      * @param sender Address initiating the swap
//      * @param key Pool key
//      * @param params Swap parameters
//      * @param hookData Additional data for the hook
//      * @return bytes4 Function selector
//      * @return BeforeSwapDelta Delta adjustments before swap
//      * @return uint24 Additional fee (if any)
//      */
//     function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata hookData) external override returns (bytes4, BeforeSwapDelta, uint24) {
//         PoolId poolId = key.toId();
//         if (isLargeSwap(params)) {
//             (int128 deltaAdjustment, int128 liquidityDelta) = adjustLiquidityForDeltaGammaHedge(key, params);
//             BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(deltaAdjustment, liquidityDelta);
//             return (BaseHook.beforeSwap.selector, beforeSwapDelta, 0);
//         } else {
//             int256 deltaImpact = int256(params.amountSpecified) / 10;
//             deltas[poolId] += deltaImpact;
//         }
//         return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
//     }

//     /**
//      * @dev Hook called after a swap
//      * @param sender Address that initiated the swap
//      * @param key Pool key
//      * @param params Swap parameters
//      * @param delta Balance delta from the swap
//      * @param hookData Additional data for the hook
//      * @return bytes4 Function selector
//      * @return int128 Additional balance delta (if any)
//      */
//     function afterSwap(
//         address sender,
//         PoolKey calldata key,
//         IPoolManager.SwapParams calldata params,
//         BalanceDelta delta,
//         bytes calldata hookData
//     ) external override returns (bytes4, int128) {
//         _rebalanceHedgingPositions(key, params);
//         _updateMetrics(key, params);
//         return (BaseHook.afterSwap.selector, 0);
//     }

//     /**
//      * @dev Determines if a swap is considered large
//      * @param params Swap parameters
//      * @return bool True if the swap is large, false otherwise
//      */
//     function isLargeSwap(IPoolManager.SwapParams calldata params) internal pure returns (bool) {
//         return params.amountSpecified > 1000000;
//     }

//     /**
//      * @dev Adjusts liquidity for Delta-Gamma hedging
//      * @param key Pool key
//      * @param params Swap parameters
//      * @return int128 Delta adjustment
//      * @return int128 Liquidity delta
//      */
//     function adjustLiquidityForDeltaGammaHedge(PoolKey calldata key, IPoolManager.SwapParams calldata params) internal returns (int128, int128) {
//         PoolId poolId = key.toId();
//         int256 gammaImpact = calculateGammaImpact(params);
//         int128 liquidityDelta = 0;
//         if (gammaImpact != 0) {
//             liquidityDelta = int128(distributeGammaHedgingLiquidity(key, gammaImpact));
//             gammas[poolId] += gammaImpact;
//         }
//         int128 deltaAdjustment = int128(adjustDeltaHedge(key, params));
//         deltas[poolId] += int256(deltaAdjustment);
//         return (deltaAdjustment, liquidityDelta);
//     }

//     /**
//      * @dev Calculates the gamma impact of a swap
//      * @param params Swap parameters
//      * @return int256 Calculated gamma impact
//      */
//     function calculateGammaImpact(IPoolManager.SwapParams calldata params) internal pure returns (int256) {
//         return int256(params.amountSpecified) * int256(GAMMA_THRESHOLD) / 1000000;
//     }

//     /**
//      * @dev Distributes liquidity for gamma hedging
//      * @param key Pool key
//      * @param gammaImpact Calculated gamma impact
//      * @return uint128 Amount of distributed liquidity
//      */
//     function distributeGammaHedgingLiquidity(PoolKey calldata key, int256 gammaImpact) internal returns (uint128) {
//         int24 tickLower = -887272;
//         int24 tickUpper = 887272;
//         uint128 liquidity = uint128(uint256(abs(gammaImpact) * 1000));

//         IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
//             tickLower: tickLower,
//             tickUpper: tickUpper,
//             liquidityDelta: int256(uint256(liquidity)),
//             salt: bytes32(0)
//         });

//         poolManager.modifyLiquidity(key, params, abi.encode(0));

//         return liquidity;
//     }

//     /**
//      * @dev Adjusts the delta hedge
//      * @param key Pool key
//      * @param params Swap parameters
//      * @return int256 Delta adjustment amount
//      */
//     function adjustDeltaHedge(PoolKey calldata key, IPoolManager.SwapParams calldata params) internal returns (int256) {
//         int256 deltaAdjustment = int256(params.amountSpecified) / 2;
//         poolManager.swap(
//             key,
//             IPoolManager.SwapParams({
//                 zeroForOne: !params.zeroForOne,
//                 amountSpecified: deltaAdjustment,
//                 sqrtPriceLimitX96: 0
//             }),
//             abi.encode(0)
//         );
//         return deltaAdjustment;
//     }

//     /**
//      * @dev Retrieves current delta and gamma values for a pool
//      * @param poolId ID of the pool
//      * @return int256 Current delta value
//      * @return int256 Current gamma value
//      */
//     function getDeltaGamma(PoolId poolId) public view returns (int256, int256) {
//         return (deltas[poolId], gammas[poolId]);
//     }

//     /**
//      * @dev Calculates the absolute value of an integer
//      * @param x Input integer
//      * @return int256 Absolute value of x
//      */
//     function abs(int256 x) internal pure returns (int256) {
//         return x >= 0 ? x : -x;
//     }

//     /**
//      * @dev Internal function to rebalance hedging positions
//      * @param key Pool key
//      * @param params Swap parameters
//      */
//     function _rebalanceHedgingPositions(PoolKey calldata key, IPoolManager.SwapParams calldata params) internal {
//         // Implementar lógica para reequilibrar posiciones de hedging
//     }

//     /**
//      * @dev Internal function to update metrics after a swap
//      * @param key Pool key
//      * @param params Swap parameters
//      */
//     function _updateMetrics(PoolKey calldata key, IPoolManager.SwapParams calldata params) internal {
//         // Actualizar métricas importantes
//     }
// }