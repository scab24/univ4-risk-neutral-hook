// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.0;

// import {Test} from "forge-std/Test.sol";
// import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
// import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
// import {PoolManager} from "v4-core/PoolManager.sol";
// import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
// import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
// import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
// import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
// import {PoolKey} from "v4-core/types/PoolKey.sol";
// import {Hooks} from "v4-core/libraries/Hooks.sol";
// import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
// import {GasPriceFeesHook} from "../src/GasPriceFeesHook.sol";
// import {TickMath} from "v4-core/libraries/TickMath.sol";
// import {console} from "forge-std/console.sol";

// contract TestGasPriceFeesHook is Test, Deployers {
//     using CurrencyLibrary for Currency;
//     using PoolIdLibrary for PoolKey;

//     GasPriceFeesHook hook;

//     function setUp() public {
//         // Deploy v4-core
//         deployFreshManagerAndRouters();

//         // Deploy, mint tokens, and approve all periphery contracts for two tokens
//         deployMintAndApprove2Currencies();

//         // Deploy our hook with the proper flags
//         address hookAddress = address(
//             uint160(
//                 Hooks.BEFORE_INITIALIZE_FLAG |
//                     Hooks.BEFORE_SWAP_FLAG |
//                     Hooks.AFTER_SWAP_FLAG
//             )
//         );

//         // Set gas price = 10 gwei and deploy our hook
//         vm.txGasPrice(10 gwei);
//         deployCodeTo("GasPriceFeesHook", abi.encode(manager), hookAddress);
//         hook = GasPriceFeesHook(hookAddress);

//         // Initialize a pool
//         (key, ) = initPool(
//             currency0,
//             currency1,
//             hook,
//             LPFeeLibrary.DYNAMIC_FEE_FLAG, // Set the `DYNAMIC_FEE_FLAG` in place of specifying a fixed fee
//             SQRT_PRICE_1_1,
//             ZERO_BYTES
//         );

//         // Add some liquidity
//         modifyLiquidityRouter.modifyLiquidity(
//             key,
//             IPoolManager.ModifyLiquidityParams({
//                 tickLower: -60,
//                 tickUpper: 60,
//                 liquidityDelta: 100 ether,
//                 salt: bytes32(0)
//             }),
//             ZERO_BYTES
//         );
//     }

//     function test_feeUpdatesWithGasPrice() public {
//         // Set up our swap parameters
//         PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
//             .TestSettings({takeClaims: false, settleUsingBurn: false});

//         IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
//             zeroForOne: true,
//             amountSpecified: -0.00001 ether,
//             sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
//         });

//         // Current gas price is 10 gwei
//         // Moving average should also be 10
//         uint128 gasPrice = uint128(tx.gasprice);
//         uint128 movingAverageGasPrice = hook.movingAverageGasPrice();
//         uint104 movingAverageGasPriceCount = hook.movingAverageGasPriceCount();
//         assertEq(gasPrice, 10 gwei);
//         assertEq(movingAverageGasPrice, 10 gwei);
//         assertEq(movingAverageGasPriceCount, 1);

//         // ----------------------------------------------------------------------
//         // ----------------------------------------------------------------------
//         // ----------------------------------------------------------------------
//         // ----------------------------------------------------------------------

//         // 1. Conduct a swap at gasprice = 10 gwei
//         // This should just use `BASE_FEE` since the gas price is the same as the current average
//         uint256 balanceOfToken1Before = currency1.balanceOfSelf();
//         swapRouter.swap(key, params, testSettings, ZERO_BYTES);
//         uint256 balanceOfToken1After = currency1.balanceOfSelf();
//         uint256 outputFromBaseFeeSwap = balanceOfToken1After -
//             balanceOfToken1Before;

//         assertGt(balanceOfToken1After, balanceOfToken1Before);

//         // Our moving average shouldn't have changed
//         // only the count should have incremented
//         movingAverageGasPrice = hook.movingAverageGasPrice();
//         movingAverageGasPriceCount = hook.movingAverageGasPriceCount();
//         assertEq(movingAverageGasPrice, 10 gwei);
//         assertEq(movingAverageGasPriceCount, 2);

//         // ----------------------------------------------------------------------
//         // ----------------------------------------------------------------------
//         // ----------------------------------------------------------------------
//         // ----------------------------------------------------------------------

//         // 2. Conduct a swap at lower gasprice = 4 gwei
//         // This should have a higher transaction fees
//         vm.txGasPrice(4 gwei);
//         balanceOfToken1Before = currency1.balanceOfSelf();
//         swapRouter.swap(key, params, testSettings, ZERO_BYTES);
//         balanceOfToken1After = currency1.balanceOfSelf();

//         uint256 outputFromIncreasedFeeSwap = balanceOfToken1After -
//             balanceOfToken1Before;

//         assertGt(balanceOfToken1After, balanceOfToken1Before);

//         // Our moving average should now be (10 + 10 + 4) / 3 = 8 Gwei
//         movingAverageGasPrice = hook.movingAverageGasPrice();
//         movingAverageGasPriceCount = hook.movingAverageGasPriceCount();
//         assertEq(movingAverageGasPrice, 8 gwei);
//         assertEq(movingAverageGasPriceCount, 3);

//         // ----------------------------------------------------------------------
//         // ----------------------------------------------------------------------
//         // ----------------------------------------------------------------------
//         // ----------------------------------------------------------------------

//         // 3. Conduct a swap at higher gas price = 12 gwei
//         // This should have a lower transaction fees
//         vm.txGasPrice(12 gwei);
//         balanceOfToken1Before = currency1.balanceOfSelf();
//         swapRouter.swap(key, params, testSettings, ZERO_BYTES);
//         balanceOfToken1After = currency1.balanceOfSelf();

//         uint outputFromDecreasedFeeSwap = balanceOfToken1After -
//             balanceOfToken1Before;

//         assertGt(balanceOfToken1After, balanceOfToken1Before);

//         // Our moving average should now be (10 + 10 + 4 + 12) / 4 = 9 Gwei
//         movingAverageGasPrice = hook.movingAverageGasPrice();
//         movingAverageGasPriceCount = hook.movingAverageGasPriceCount();

//         assertEq(movingAverageGasPrice, 9 gwei);
//         assertEq(movingAverageGasPriceCount, 4);

//         // ------

//         // 4. Check all the output amounts

//         console.log("Base Fee Output", outputFromBaseFeeSwap);
//         console.log("Increased Fee Output", outputFromIncreasedFeeSwap);
//         console.log("Decreased Fee Output", outputFromDecreasedFeeSwap);

//         assertGt(outputFromDecreasedFeeSwap, outputFromBaseFeeSwap);
//         assertGt(outputFromBaseFeeSwap, outputFromIncreasedFeeSwap);
//     }
// }
