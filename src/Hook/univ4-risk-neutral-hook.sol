// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Necessary imports from Uniswap v4
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";

// OpenZeppelin imports for access control
import "@openzeppelin/contracts/access/Ownable.sol";

// Chainlink imports for obtaining external data
import "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "abdk-libraries-solidity/ABDKMath64x64.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {VolatilityCalculator} from "../Math/implied volatility_solidity.sol";

/**
 * @title univ4-risk-neutral-hook
 * @notice Uniswap v4 Hook to dynamically adjust fees based on gas price and market data.
 *         Utilizes an Exponential Moving Average (EMA) for gas price and Chainlink oracles to obtain volatility, liquidity, and volume data.
 */
contract univ4riskneutralhook is BaseHook, Ownable {
    using LPFeeLibrary for uint24; // Library to handle liquidity fees
    using ABDKMath64x64 for int128;
    using ABDKMath64x64 for uint256;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /**
     * @notice Structure to store market data obtained from oracles
     */
    // [@mevquant]: Does volatility make sense as uint256? Or is it overkill to be so large?
    struct MarketData {
        uint256 volatility; // Market volatility based on 10000 (e.g., 500 = 5%)
        uint256 liquidity;   // Total liquidity in the pool (tokens with 18 decimals)
        uint256 volume;      // Transaction volume in the period (tokens with 18 decimals)
        uint256 lastUpdateTimestamp; // Timestamp of the last market data update
    }

    /**
     * @notice Structure to maintain the context of each individual swap
     */
    struct SwapContext {
        int256 initialAmountSpecified; // Initial amount specified for the swap
        uint256 initialGasPrice;       // Gas price at the start of the swap
        uint24 fee;                     // Custom fee applied to the swap
        uint256 timestamp;             // Timestamp of the swap
        uint256 volatility;            // Market volatility at the start of the swap
        uint256 liquidity;             // Pool liquidity at the start of the swap
        //@audit => add realized Volatility
    }

    // Mapping of market data by pool address
    mapping(address => MarketData) public marketDataByPool;

    // Mapping of swap contexts by swapId
    mapping(bytes32 => SwapContext) private swapContexts;

    // Exponential Moving Average (EMA) of gas price
    uint128 public movingAverageGasPrice;

    // Parameters for calculating EMA
    // [@mevquant]: Add Smoothing and Precision to the name for clarity:
    uint128 public emaSmoothingFactor = 100;   // Smoothing factor (10%)
    uint128 public emaPrecisionDivider = 1000; // Divider to maintain precision (100%)

    // Dynamic fee settings
    uint24 public constant BASE_FEE = 3000; // Base fee of 0.3%
    uint24 public constant MAX_FEE = 10000; // Maximum fee of 1%
    uint24 public constant MIN_FEE = 500;   // Minimum fee of 0.05%

    // Adjustable parameters by the owner
    uint256 public gasPriceThreshold = 20;        // Gas price difference threshold (%)
    uint256 public maxSwapSize = 1_000_000e18;     // Maximum swap size (1 million tokens)
    uint256 public volatilityThreshold = 500;      // Volatility threshold (5%)
    uint256 public lowLiquidityThreshold = 100_000e18; // Low liquidity threshold (100,000 tokens)
    uint256 public highVolumeThreshold = 300_000e18;   // High volume threshold (300,000 tokens)
    uint256 public lowVolumeThreshold = 100_000e18;    // Low volume threshold (100,000 tokens)

    // Chainlink oracle interfaces for obtaining data
    AggregatorV3Interface internal volatilityOracle;
    AggregatorV3Interface internal realizedVolatility; //@audit new
    AggregatorV3Interface internal priceFeed; //@audit new
    AggregatorV3Interface internal liquidityOracle;
    AggregatorV3Interface internal volumeOracle;

    VolatilityCalculator public volatilityCalculator;

    // Nonce to generate unique swapId and avoid collisions
    uint256 private swapNonce;

    /**
     * @notice Constructor that initializes the hook and sets the oracle addresses.
     * @param _poolManager Address of the Uniswap v4 PoolManager.
     * @param _volatilityOracle Address of the Chainlink oracle for volatility.
     * @param _realizedVolatility Address of the Chainlink oracle for realized volatility.
     * @param _priceFeed Address of the Chainlink price feed.
     * @param _liquidityOracle Address of the Chainlink oracle for liquidity.
     * @param _volumeOracle Address of the Chainlink oracle for volume.
     */
    constructor(
        IPoolManager _poolManager,
        address _volatilityOracle,
        address _realizedVolatility,
        address _priceFeed,
        address _liquidityOracle,
        address _volumeOracle
    ) BaseHook(_poolManager) Ownable(msg.sender){
        // Initialize Chainlink oracle interfaces
        volatilityOracle = AggregatorV3Interface(_volatilityOracle);
        realizedVolatility = AggregatorV3Interface(_realizedVolatility); //@audit new
        priceFeed = AggregatorV3Interface(_priceFeed); //@audit new
        liquidityOracle = AggregatorV3Interface(_liquidityOracle);
        volumeOracle = AggregatorV3Interface(_volumeOracle);
        volatilityCalculator = new VolatilityCalculator();

        // Initialize the gas price moving average with the current gas price
        uint128 initialGasPrice = uint128(tx.gasprice);
        initializeEMA(initialGasPrice);
    }

    /**
     * @notice Initializes the Exponential Moving Average (EMA) with the first gas price.
     * @param initialGasPrice Initial gas price.
     */
    function initializeEMA(uint128 initialGasPrice) internal {
        movingAverageGasPrice = initialGasPrice;
    }

    /**
     * @notice Defines which hooks are enabled in this contract.
     * @return permissions Structure with hook permissions.
     */
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
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


    // function beforeInitialize(
    //     address,
    //     PoolKey calldata key,
    //     uint160,
    //     bytes calldata
    // ) external pure override returns (bytes4) {
    //     // `.isDynamicFee()` function comes from using
    //     // the `SwapFeeLibrary` for `uint24`
    //     if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
    //     return this.beforeInitialize.selector;
    // }

    /**
     * @notice Function executed before a swap.
     *         Calculates and adjusts the dynamic fee based on market data and gas price.
     * @param sender Address calling the hook (PoolManager).
     * @param key Key information of the pool.
     * @param params Swap parameters.
     * @param data Additional data (unused).
     * @return selector Function selector.
     * @return customDelta Custom delta to adjust the swap (no adjustments in this example).
     * @return customFee Custom fee for the swap.
     */
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata data
    )
        external
        override
        /*onlyByPoolManager*/
        returns (
            bytes4 selector,
            BeforeSwapDelta customDelta,
            uint24 customFee
        )
    {
        //@audit => Research not found
        //import {PoolKey} from "v4-core/types/PoolKey.sol";
        // address poolAddress = address(key.pool);
        address poolAddress;

        // Validate that the specified amount is not zero
        require(params.amountSpecified != 0, "Amount specified cannot be zero");

        //@audit-ok TODO - => gamma
        // Obtain liquidity from Uniswap v4
        uint256 liquidity = poolManager.getLiquidity(key.toId());

        // Update market data using real oracles
        updateMarketData(poolAddress);

        // Calculate custom fee based on market data and gas price
        customFee = calculateCustomFee(poolAddress, params.amountSpecified);

        // Get the current fee of the pool to compare with the newly calculated fee
        uint128 currentFee = uint128(tx.gasprice);

        // If the calculated fee is different from the current fee, update the fee in the PoolManager

        // [@mevquant]: Could this cause decimal issues? Maybe better to set a x% difference
        // parameter uint24 _tolerance or something like 10000
        // e.g. [100%], 1000 [10%], 100 [1%], 10 [0.1%], 1 [0.01%]
        // Q: Is the fee modified per swap or per pool? That is, do we change it for all swaps in that block?
        if (customFee != currentFee) {
            poolManager.updateDynamicLPFee(key, customFee);
            // emit FeeAdjusted(poolAddress, currentFee, customFee);
        }

        // Generate a unique swapId by combining the pool address and the swapNonce
        // [@mevquant]: Maybe add some "salt" like block.number / timestamp? [future block same nonce]
        bytes32 swapId = keccak256(abi.encodePacked(poolAddress, swapNonce));
        swapNonce += 1; // Increment the nonce for the next swap

        // Store the swap context for adjustments later in 'afterSwap'
        swapContexts[swapId] = SwapContext({
            initialAmountSpecified: params.amountSpecified,
            initialGasPrice: tx.gasprice,
            fee: customFee,
            timestamp: block.timestamp,
            volatility: marketDataByPool[poolAddress].volatility,
            liquidity: marketDataByPool[poolAddress].liquidity
        });

        // Create BeforeSwapDelta (no adjustment in this example)
        customDelta = BeforeSwapDeltaLibrary.ZERO_DELTA;

        // Return the function selector, custom delta, and calculated fee
        // Add Delta / Gamma
        /**
         * struct Greeks {
         *  int24 delta;
         *  int24 gamma;
         * }
         */ 
        // mapping (address => Greeks greeks)
        // updateGreeks()
        return (this.beforeSwap.selector, customDelta, customFee);
    }

    /**
     * @notice Function executed after a swap.
     *         Updates the moving average of the gas price and performs post-swap adjustments.
     * @param sender Address calling the hook (PoolManager).
     * @param key Key information of the pool.
     * @param params Swap parameters.
     * @param actualDelta Actual delta of the swap.
     * @param data Additional data (unused).
     * @return selector Function selector.
     * @return adjustment Post-swap adjustment (unused in this example).
     */
    // [@mevquant]: Maybe here it's a good idea to only save the 30d EMA of the IV
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta actualDelta,
        bytes calldata data
    )
        external
        override
        /*onlyByPoolManager*/
        returns (bytes4 selector, int128 adjustment)
    {
        //@audit => Research not found
        //import {PoolKey} from "v4-core/types/PoolKey.sol";
        // address poolAddress = address(key.pool);
        address poolAddress;

        // Generate the corresponding swapId for the current swap using 'swapNonce - 1'
        bytes32 swapId = keccak256(abi.encodePacked(poolAddress, swapNonce - 1));
        SwapContext memory context = swapContexts[swapId];

        // Validate that the swap context exists
        require(context.timestamp != 0, "Swap context not found");

        // Calculate fee adjustment based on gas price difference, slippage, and changes in volatility and liquidity
        adjustment = calculateAdjustment(context, actualDelta, poolAddress);

        // Delete the swap context to free storage and avoid future references
        delete swapContexts[swapId];

        // Emit post-swap adjustment event
        // emit SwapAdjusted(poolAddress, adjustment);

        // Update the gas price moving average with the gas price of this swap
        updateMovingAverage();

        // Return the function selector and the calculated adjustment
        return (this.afterSwap.selector, adjustment);
    }

    /**
     * @notice Calculates the custom fee based on multiple factors: volatility, volume, swap size, liquidity, and gas price.
     * @param poolAddress Address of the pool.
     * @param amountSpecified Specified amount of the swap.
     * @return fee Custom fee based on 10_000 (e.g., 3000 = 30%) 
     */
    //[@mevquant] Q, wouldn't it be: 10_000 = 100%, 1,000 = 10%, 100 = 1%, 10 = 0.1%, 1 = 0.01%.
    function calculateCustomFee(address poolAddress, int256 amountSpecified)
        internal
        view
        returns (uint24 fee)
    {
        fee = BASE_FEE;
        MarketData memory data = marketDataByPool[poolAddress];

        // Adjust for volatility: increase the fee proportionally to volatility
        //@audit => change
        // fee = (fee * (10000 + data.volatility)) / 10000;
        fee = uint24((uint256(fee) * (10000 + data.volatility)) / 10000);

        // Adjust for transaction volume
        if (data.volume > highVolumeThreshold) {
            fee = (fee * 90) / 100; // Reduce by 10% if volume is high
        } else if (data.volume < lowVolumeThreshold) {
            fee = (fee * 110) / 100; // Increase by 10% if volume is low
        }

        // Adjust for swap size
        if (isLargeSwap(amountSpecified)) {
            fee = (fee * 120) / 100; // Increase by 20% for large swaps
        }

        // Adjust for liquidity
        if (data.liquidity < lowLiquidityThreshold) {
            fee = (fee * 150) / 100; // Increase by 50% in low liquidity
        }

        // Adjust for gas price using EMA
        uint256 gasPriceDifference = calculateGasPriceDifference();
        if (gasPriceDifference > gasPriceThreshold) {
            if (tx.gasprice > movingAverageGasPrice) {
                fee = (fee * 80) / 100; // Reduce by 20% if gas is significantly higher
            } else {
                fee = (fee * 120) / 100; // Increase by 20% if gas is significantly lower
            }
        }

        // Ensure the final fee is within the established limits
        fee = uint24(min(max(uint256(fee), MIN_FEE), MAX_FEE));

        return fee;
    }

    /**
     * @notice Calculates the fee adjustment post-swap based on various factors: gas price difference, slippage, and changes in volatility and liquidity.
     * @param context Swap context stored in 'swapContexts'.
     * @param actualDelta Actual delta of the swap.
     * @param poolAddress Address of the pool.
     * @return adjustment Calculated adjustment (can be positive or negative).
     */
    function calculateAdjustment(
        SwapContext memory context,
        BalanceDelta actualDelta,
        address poolAddress
    )
        internal
        view
        returns (int128 adjustment)
    {
        // Gas price difference between the current swap and the average
        int256 gasPriceDifference = int256(tx.gasprice) - int256(context.initialGasPrice);
        //@audit => change
        // int128 baseAdjustment = int128((gasPriceDifference * int256(context.fee)) / 1e9);
        int128 baseAdjustment = int128((gasPriceDifference * int256(uint256(context.fee))) / 1e9);

        // Slippage calculation: difference between the actual and specified amount
        int256 actualAmount = int256(actualDelta.amount0()) + int256(actualDelta.amount1());
        int256 slippage = actualAmount - context.initialAmountSpecified;
        int128 slippageAdjustment = int128(slippage / 1000); // 0.1% of the slippage

        // Adjustment for changes in volatility and liquidity since the start of the swap
        MarketData memory currentData = marketDataByPool[poolAddress];
        int256 volatilityChange = int256(currentData.volatility) - int256(context.volatility);
        int256 liquidityChange = int256(currentData.liquidity) - int256(context.liquidity);

        // Initialize additional adjustment
        int128 marketConditionAdjustment = 0;

        // Adjust for volatility if there have been changes
        if (volatilityChange != 0) {
            // Adjust the fee proportionally to the volatility difference
            //@audit => change
            // marketConditionAdjustment += int128((volatilityChange * int256(context.fee)) / 10000);
            marketConditionAdjustment += int128((volatilityChange * int256(uint256(context.fee))) / 10000);
        }

        // Adjust for liquidity if there have been changes
        if (liquidityChange != 0) {
            // Adjust the fee proportionally to the liquidity difference (large scale to avoid overflows)
            //@audit => change
            // marketConditionAdjustment += int128((liquidityChange * int256(context.fee)) / 1e22);
            marketConditionAdjustment += int128((liquidityChange * int256(uint256(context.fee))) / 1e22);
        }

        // Sum all adjustments to get the total adjustment
        adjustment = baseAdjustment + slippageAdjustment + marketConditionAdjustment;
    }

    /**
     * @notice Updates the Exponential Moving Average (EMA) of the gas price.
     *         Incorporates the current gas price with a smoothing factor.
     */
    function updateMovingAverage() internal {
        uint128 currentGasPrice = uint128(tx.gasprice);
        if (movingAverageGasPrice == 0) {
            // If EMA is not initialized, initialize it with the current gas price
            initializeEMA(currentGasPrice);
        } else {
            // Calculate the new EMA with the current gas price
            movingAverageGasPrice =
                ((currentGasPrice * emaSmoothingFactor) + (movingAverageGasPrice * (emaPrecisionDivider - emaSmoothingFactor))) /
                emaPrecisionDivider;
        }
    }

    /**
     * @notice Calculates the percentage difference between the current gas price and the moving average.
     * @return gasPriceDifference Percentage difference (%).
     */
    function calculateGasPriceDifference() internal view returns (uint256 gasPriceDifference) {
        // [@mevquant]: For example, we have tx.gasprice, would it make sense to look at the middle of the block?
        uint128 gasPrice = uint128(tx.gasprice);
        if (movingAverageGasPrice == 0) return 0; // Avoid division by zero

        uint256 difference;
        if (gasPrice > movingAverageGasPrice) {
            // Calculate percentage difference when gasPrice is greater than average
            difference = ((gasPrice - movingAverageGasPrice) * 100) / movingAverageGasPrice;
        } else {
            // Calculate percentage difference when gasPrice is less than average
            difference = ((movingAverageGasPrice - gasPrice) * 100) / movingAverageGasPrice;
        }

        gasPriceDifference = difference;
    }

    /**
     * @notice Checks if the swap is considered large based on the specified size.
     * @param amountSpecified Specified amount of the swap.
     * @return bool Indicator if it's a large swap.
     */
    function isLargeSwap(int256 amountSpecified) internal view returns (bool) {
        // Consider a swap large if the specified amount is greater than half the maximum swap size
        //@audit => change
        // return abs(amountSpecified) > (int256(maxSwapSize) / 2);
        return uint256(abs(amountSpecified)) > (maxSwapSize / 2);
    }

    /**
     * @notice Calculates the absolute value of an integer.
     * @param x Integer.
     * @return absValue Absolute value of x.
     */
    function abs(int256 x) internal pure returns (uint256 absValue) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    /**
     * @notice Returns the minimum of two numbers.
     * @param a First number.
     * @param b Second number.
     * @return minValue Minimum value between a and b.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256 minValue) {
        return a < b ? a : b;
    }

    /**
     * @notice Returns the maximum of two numbers.
     * @param a First number.
     * @param b Second number.
     * @return maxValue Maximum value between a and b.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256 maxValue) {
        return a > b ? a : b;
    }

    /**
     * @notice Updates the market data using real Chainlink oracles.
     * @param poolAddress Address of the pool.
     */
    function updateMarketData(address poolAddress) internal {
        // Obtain new market data from the oracles
        MarketData memory newData = fetchMarketData(poolAddress);

        // Store the new market data in the mapping corresponding to the pool
        marketDataByPool[poolAddress] = newData;

        // Emit the 'MarketDataUpdated' event with the new information
        // emit MarketDataUpdated(
        //     poolAddress,
        //     newData.volatility,
        //     newData.liquidity,
        //     newData.volume,
        //     newData.lastUpdateTimestamp
        // );
    }

    /**
     * @notice Retrieves market data from Chainlink oracles.
     * @param poolAddress Address of the pool.
     * @return data Structure with the updated market data.
     */
    function fetchMarketData(address poolAddress) internal view returns (MarketData memory data) {

        //@audit-ok => TODO in BREVIS ?
        // Obtain volatility from Chainlink's volatility oracle
        (, int256 volatilityPrice, , uint256 volatilityUpdatedAt, ) = volatilityOracle.latestRoundData();
        uint256 v_volatility = uint256(volatilityPrice); // Assuming the oracle returns volatility based on 10000

        //@@audit-ok  => OK
        // Obtain realized volatility from Chainlink
        // https://docs.chain.link/data-feeds/rates-feeds/addresses?network=ethereum&page=1
        (, int volatility,,,) = realizedVolatility.latestRoundData();
        int r_volatility = volatility; // Corrected: conversion not necessary

        //@@audit-ok  => OK
        // Obtain Price Feeds
        // https://docs.chain.link/data-feeds/price-feeds/addresses?network=ethereum&page=1
        (, int price, , ,) = priceFeed.latestRoundData();
        // No need to convert price, already an int

        //@@audit-ok  TODO - => gamma OK
        // Obtain liquidity from Uniswap v4 ====>>> IN BEFORE_SWAP
        // uint256 liquidity = poolManager.getLiquidity(key.toId());
        uint256 liquidity;

        //@audit => TODO => implied volatility => OK (Adjust)
        // Convert values to 64.64 fixed format and adjust decimals as needed
        int128 muPool = ABDKMath64x64.fromInt(price).div(ABDKMath64x64.fromUInt(1e8)); // if 'currentPrice' has 8 decimals

        uint256 t = 1; // Time in years

        // Parameters for iteration
        uint256 maxIterations = 10;
        int128 tolerance = ABDKMath64x64.div(ABDKMath64x64.fromUInt(1), ABDKMath64x64.fromUInt(1e6)); // Tolerance of 0.000001

        // Iteratively calculate sigma and u
        (int128 sigma, int128 u) = computeImpliedVolatilityAndDriftIterative(muPool, t, maxIterations, tolerance);


        //@audit TODO => BREVIS
        // Obtain volume 
        (, int256 volumePrice, , uint256 volumeUpdatedAt, ) = volumeOracle.latestRoundData();
        uint256 volume = uint256(volumePrice); 

        // Create the 'MarketData' structure with the obtained values
        //@audit => TODO add marketdata
        data = MarketData({
            volatility: uint256(r_volatility), // Assuming MarketData.volatility is uint256
            liquidity: liquidity,
            volume: volume,
            lastUpdateTimestamp: block.timestamp
        });
    }

    // IV

    // Function to calculate implied volatility and drift iteratively
    function computeImpliedVolatilityAndDriftIterative(int128 muPool, uint256 t, uint256 maxIterations, int128 tolerance) internal view returns (int128 sigma, int128 u) {
        // Initial estimate of u
        u = muPool;
        int128 previousU;
        int128 difference;

        for (uint256 i = 0; i < maxIterations; i++) {
            // Save the previous value of u
            previousU = u;

            // Calculate sigma given u
            sigma = computeSigma(muPool, u, t);

            // Calculate new u given sigma
            u = volatilityCalculator.calculateDrift(muPool, sigma);

            // Calculate the absolute difference
            difference = absv(u.sub(previousU));

            // Check for convergence
            if (difference < tolerance) {
                break; // Converged
            }
        }
    }

    // Function to calculate sigma given u
    function computeSigma(int128 muPool, int128 u, uint256 t) internal view returns (int128 sigma) {
        // Calculate u * t / 2
        int128 utOver2 = u.mul(ABDKMath64x64.fromUInt(t)).div(ABDKMath64x64.fromUInt(2));

        // Calculate cosh(u * t / 2) using VolatilityCalculator
        int128 coshUtOver2 = volatilityCalculator.cosh(utOver2);

        // Calculate ln(cosh(u * t / 2)) using VolatilityCalculator
        int128 lnCoshUtOver2 = volatilityCalculator.approximateLn(coshUtOver2);

        // Calculate [mu_pool * t - ln(cosh(u * t / 2))]
        int128 muPoolTimesT = muPool.mul(ABDKMath64x64.fromUInt(t));
        int128 innerExpression = muPoolTimesT.sub(lnCoshUtOver2);

        // Calculate 8 / t
        int128 eightOverT = ABDKMath64x64.fromUInt(8).div(ABDKMath64x64.fromUInt(t));

        // Calculate multiplicand
        int128 multiplicand = eightOverT.mul(innerExpression);

        // Calculate sigma as the square root of the multiplicand
        sigma = sqrt(multiplicand);
    }

    // Function to calculate the square root
    function sqrt(int128 x) internal view returns (int128) {
        return volatilityCalculator.sqrt(x);
    }

    // Function to calculate the absolute value
    function absv(int128 x) internal pure returns (int128) {
        return x >= 0 ? x : x.neg();
    }


    ///////////////////
    // Brevis 
    ///////////////////

    //volume => TODO
    // function handleProofResult(
    //     bytes32 /*_requestId*/,
    //     bytes32 _vkHash,
    //     bytes calldata _circuitOutput
    // ) internal override {

    //     require(vkHash == _vkHash, "invalid vk");
    //     (bytes32 _, uint64 sumVolume, uint64 minBlockNum, address addr) = decodeOutput(_circuitOutput);
    //     emit TradingVolumeAttested(addr, sumVolume, minBlockNum);
    // }

    // // In guest circuit we have:
    // // api.OutputBytes32(Salt)
    // // api.OutputUint(248, sumVolume)
    // // api.OutputUint(64, minBlockNum)
    // // api.OutputAddress(c.UserAddr)
    // function decodeOutput(bytes calldata o) internal pure returns (bytes32, uint256, uint64, address) {
    //     bytes32 salt = bytes32(o[0:32]);

    //     uint256 sumVolume = uint256(bytes31(o[32:63]));
    //     uint64 minBlockNum = uint64(bytes8(o[63:71]));
    //     address addr = address(bytes20(o[71:91]));
    //     return (salt, sumVolume, minBlockNum, addr);
    // }

    // function setVkHash(bytes32 _vkHash) external onlyOwner {
    //     vkHash = _vkHash;
    // }

}