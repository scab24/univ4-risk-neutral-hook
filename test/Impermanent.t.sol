// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {DeltaGammaHedgingHook} from "../src/DeltaGammaHedgingHook.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";


import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";



contract DeltaGammaHedgingHookTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    DeltaGammaHedgingHook hook;

function setUp() public {
    // Desplegar contratos core de v4
    deployFreshManagerAndRouters();

    // Desplegar dos tokens de prueba
    (currency0, currency1) = deployMintAndApprove2Currencies();

    // Configurar los flags hook
    uint160 flags = uint160(
        Hooks.BEFORE_SWAP_FLAG | 
        Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );
    address hookAddress = address(flags);

    // Desplegar hook
    deployCodeTo("DeltaGammaHedgingHook.sol", abi.encode(manager), hookAddress);
    hook = DeltaGammaHedgingHook(hookAddress);

    // Inicializar un pool
    (key, ) = initPool(
        currency0,
        currency1,
        hook,
        3000,
        SQRT_PRICE_1_1,
        ZERO_BYTES
    );

    // Agregar liquidez inicial
    modifyLiquidityRouter.modifyLiquidity(
        key,
        IPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: 1000 ether,
            salt: bytes32(0)
        }),
        ZERO_BYTES
    );
}
function testBeforeSwap() public {
    PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
        takeClaims: false,
        settleUsingBurn: false
    });

    // Registra los balances iniciales
    uint balanceOfToken0Before = key.currency0.balanceOfSelf();
    uint balanceOfToken1Before = key.currency1.balanceOfSelf();

    // Realiza el swap
    swapRouter.swap(
        key,
        IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1000000, // Swap exacto de 1 millón de unidades del token0
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        }),
        settings,
        ZERO_BYTES
    );

    // Registra los balances después del swap
    uint balanceOfToken0After = key.currency0.balanceOfSelf();
    uint balanceOfToken1After = key.currency1.balanceOfSelf();

    // Verifica que el swap se realizó correctamente
    assertEq(balanceOfToken0Before - balanceOfToken0After, 1000000, "El balance de token0 no cambio como se esperaba");
    assertTrue(balanceOfToken1After > balanceOfToken1Before, "El balance de token1 no aumento");
}

// function alignTick(int24 tick, int24 tickSpacing) internal pure returns (int24) {
//     int24 compressed = tick / tickSpacing;
//     return compressed * tickSpacing;
// }

// function testDeltaGammaAdjustment() public {
//     PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
//         takeClaims: false,
//         settleUsingBurn: false
//     });

//     (int256 initialDelta, int256 initialGamma) = hook.getDeltaGamma(key.toId());

//     uint128 liquidity = uint128(StateLibrary.getLiquidity(manager, key.toId()));
//     int256 swapAmount = int256(uint256(liquidity) / 10);

//     (, int24 currentTick, , ) = StateLibrary.getSlot0(manager, key.toId());

//     int24 tickSpacing = key.tickSpacing;
//     int24 tickLower = alignTick(currentTick - 887272, tickSpacing);
//     int24 tickUpper = alignTick(currentTick + 887272, tickSpacing);

//     tickLower = tickLower < TickMath.MIN_TICK ? TickMath.MIN_TICK : tickLower;
//     tickUpper = tickUpper > TickMath.MAX_TICK ? TickMath.MAX_TICK : tickUpper;

//     try swapRouter.swap(
//         key,
//         IPoolManager.SwapParams({
//             zeroForOne: true,
//             amountSpecified: swapAmount,
//             sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickLower)
//         }),
//         settings,
//         abi.encode(tickLower, tickUpper)
//     ) {
//         (int256 newDelta, int256 newGamma) = hook.getDeltaGamma(key.toId());
//         assertLt(newDelta, initialDelta, "Delta deberia haber disminuido");
//         assertGt(newGamma, initialGamma, "Gamma deberia haber aumentado");

//         uint256 hookBalance0After = currency0.balanceOf(address(hook));
//         uint256 hookBalance1After = currency1.balanceOf(address(hook));
//         int256 actualBalanceChange = int256(hookBalance1After) - int256(hookBalance0After);
//         assertApproxEqRel(actualBalanceChange, initialDelta - newDelta, 1e16, "El ajuste de posicion del hook no coincide con el cambio de delta");

//         for (int24 i = 1; i <= 5; i++) {
//             (int256 preDelta, int256 preGamma) = hook.getDeltaGamma(key.toId());
//             swapRouter.swap(
//                 key,
//                 IPoolManager.SwapParams({
//                     zeroForOne: true,
//                     amountSpecified: swapAmount / 5,
//                     sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(alignTick(currentTick - i * 10 * tickSpacing, tickSpacing))
//                 }),
//                 settings,
//                 abi.encode(tickLower, tickUpper)
//             );
//             (int256 postDelta, int256 postGamma) = hook.getDeltaGamma(key.toId());
//             assertLt(postDelta, preDelta, "Delta deberia disminuir en cada swap");
//             assertGt(postGamma, preGamma, "Gamma deberia aumentar en cada swap");
//         }

//         swapRouter.swap(
//             key,
//             IPoolManager.SwapParams({
//                 zeroForOne: true,
//                 amountSpecified: swapAmount,
//                 sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickLower + tickSpacing)
//             }),
//             settings,
//             abi.encode(tickLower, tickUpper)
//         );

//         (int256 finalDelta, int256 finalGamma) = hook.getDeltaGamma(key.toId());
//         assertLt(finalDelta, initialDelta, "Delta final deberia ser menor que la inicial");
//         assertGt(finalGamma, initialGamma, "Gamma final deberia ser mayor que la inicial");

//     } catch Error(string memory reason) {
//         revert(string(abi.encodePacked("Test fallido: ", reason)));
//     }
// }


}