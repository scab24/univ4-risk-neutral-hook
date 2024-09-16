// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Importaciones necesarias de Uniswap v4
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";

// Importaciones de OpenZeppelin para control de acceso
import "@openzeppelin/contracts/access/Ownable.sol";

// Importaciones de Chainlink para obtener datos externos
import "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "abdk-libraries-solidity/ABDKMath64x64.sol";
/**
 * @title GasPriceFeesHook
 * @notice Hook de Uniswap v4 para ajustar dinámicamente las tarifas basadas en el precio del gas y datos de mercado.
 *         Utiliza un Promedio Móvil Exponencial (EMA) para el precio del gas y oráculos de Chainlink para obtener datos de volatilidad, liquidez y volumen.
 */
contract GasPriceFeesHook is BaseHook, Ownable {
    using LPFeeLibrary for uint24; // Biblioteca para manejar tarifas de liquidez
    using ABDKMath64x64 for int128;
    using ABDKMath64x64 for uint256;

    /**
     * @notice Estructura para almacenar datos de mercado obtenidos de oráculos
     */
    // [@mevquant]: Tiene sentido volatility como uint256? O es overkill que sea tan grande?
    struct MarketData {
        uint256 volatility; // Volatilidad del mercado en base 10000 (e.g., 500 = 5%)
        uint256 liquidity;   // Liquidez total en el pool (tokens con 18 decimales)
        uint256 volume;      // Volumen de transacciones en el periodo (tokens con 18 decimales)
        uint256 lastUpdateTimestamp; // Timestamp de la última actualización de datos de mercado
    }

    /**
     * @notice Estructura para mantener el contexto de cada swap individual
     */
    struct SwapContext {
        int256 initialAmountSpecified; // Monto inicial especificado para el swap
        uint256 initialGasPrice;       // Precio del gas al inicio del swap
        uint24 fee;                     // Tarifa personalizada aplicada al swap
        uint256 timestamp;             // Timestamp del swap
        uint256 volatility;            // Volatilidad del mercado al inicio del swap
        uint256 liquidity;             // Liquidez del pool al inicio del swap
        //@audit => add realiced Volatility
    }

    // Mapeo de datos de mercado por dirección de pool
    mapping(address => MarketData) public marketDataByPool;

    // Mapeo de contexto de swaps por swapId
    mapping(bytes32 => SwapContext) private swapContexts;

    // Promedio Móvil Exponencial (EMA) del precio del gas
    uint128 public movingAverageGasPrice;

    // Parámetros para calcular el EMA
    // [@mevquant]: Añadir Smoothing y Precision al nombre por claridad:
    uint128 public emaSmoothingFactor = 100;   // Factor de suavizado (10%)
    uint128 public emaPrecisionDivider = 1000; // Denominador para mantener la precisión (100%)

    // Configuración de tarifas dinámicas
    uint24 public constant BASE_FEE = 3000; // Tarifa base de 0.3%
    uint24 public constant MAX_FEE = 10000; // Tarifa máxima de 1%
    uint24 public constant MIN_FEE = 500;   // Tarifa mínima de 0.05%

    // Parámetros ajustables por el propietario (owner)
    uint256 public gasPriceThreshold = 20;        // Umbral de diferencia del precio del gas (%)
    uint256 public maxSwapSize = 1_000_000e18;     // Tamaño máximo del swap (1 millón de tokens)
    uint256 public volatilityThreshold = 500;      // Umbral de volatilidad (5%)
    uint256 public lowLiquidityThreshold = 100_000e18; // Umbral de liquidez baja (100,000 tokens)
    uint256 public highVolumeThreshold = 300_000e18;   // Umbral de volumen alto (300,000 tokens)
    uint256 public lowVolumeThreshold = 100_000e18;    // Umbral de volumen bajo (100,000 tokens)

    // Interfaces de Chainlink para obtener datos de oráculos
    AggregatorV3Interface internal volatilityOracle;
    AggregatorV3Interface internal realizedVolatility; //@audit new
    AggregatorV3Interface internal priceFeed; //@audit new
    AggregatorV3Interface internal liquidityOracle;
    AggregatorV3Interface internal volumeOracle;

    // Nonce para generar swapId único y evitar colisiones
    uint256 private swapNonce;

    /**
     * @notice Constructor que inicializa el hook y establece las direcciones de los oráculos.
     * @param _poolManager Dirección del PoolManager de Uniswap v4.
     * @param _volatilityOracle Dirección del oráculo de Chainlink para volatilidad.
     * @param _liquidityOracle Dirección del oráculo de Chainlink para liquidez.
     * @param _volumeOracle Dirección del oráculo de Chainlink para volumen.
     */
    constructor(
        IPoolManager _poolManager,
        address _volatilityOracle,
        address _realizedVolatility,
        address _priceFeed,
        address _liquidityOracle,
        address _volumeOracle
    ) BaseHook(_poolManager) Ownable(msg.sender){
        // Inicializar las interfaces de los oráculos de Chainlink
        volatilityOracle = AggregatorV3Interface(_volatilityOracle);
        realizedVolatility = AggregatorV3Interface(_realizedVolatility); //@audit new
        priceFeed = AggregatorV3Interface(_priceFeed); //@audit new
        liquidityOracle = AggregatorV3Interface(_liquidityOracle);
        volumeOracle = AggregatorV3Interface(_volumeOracle);

        // Inicializar el promedio móvil del gas con el precio del gas actual
        uint128 initialGasPrice = uint128(tx.gasprice);
        initializeEMA(initialGasPrice);
    }

    /**
     * @notice Inicializa el Promedio Móvil Exponencial (EMA) con el primer precio del gas.
     * @param initialGasPrice Precio del gas inicial.
     */
    function initializeEMA(uint128 initialGasPrice) internal {
        movingAverageGasPrice = initialGasPrice;
    }

    /**
     * @notice Define qué hooks están habilitados en este contrato.
     * @return permissions Estructura con las permisos de los hooks.
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
     * @notice Función que se ejecuta antes de un swap.
     *         Calcula y ajusta la tarifa dinámica basada en datos de mercado y precio del gas.
     * @param sender Dirección que llama al hook (PoolManager).
     * @param key Información clave del pool.
     * @param params Parámetros del swap.
     * @param data Datos adicionales (no utilizados).
     * @return selector Selector de la función.
     * @return customDelta Delta personalizado para ajustar el swap (sin ajustes en este ejemplo).
     * @return customFee Tarifa personalizada para el swap.
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
        //@audit => Research no found
        //import {PoolKey} from "v4-core/types/PoolKey.sol";
        // address poolAddress = address(key.pool);
        address poolAddress;

        // Validar que el monto especificado no sea cero
        require(params.amountSpecified != 0, "Amount specified cannot be zero");

        // Actualizar datos de mercado usando oráculos reales
        updateMarketData(poolAddress);

        // Calcular tarifa personalizada basada en los datos de mercado y precio del gas
        customFee = calculateCustomFee(poolAddress, params.amountSpecified);

        // Obtener la tarifa actual del pool para compararla con la nueva tarifa calculada
        //@audit => pending => (tx.gasprice)
        // uint24 currentFee = poolManager.getFee(key); 
        uint128 currentFee = uint128(tx.gasprice);

        // Si la tarifa calculada es diferente a la actual, actualizar la tarifa en el PoolManager

        // [@mevquant]: Aqui se puede liar por decimales? Igual mejor poner un x% de diferencia
        // parametro uint24 _tolerance o algo asi 10000 
        // e.g. [100%], 1000 [10%], 100 [1%], 10 [0.1%], 1 [0.01%]
        // Q: La fee cuando la modificamos es por swap o por pool? Es decir, la cambiamos para todos los swaps de ese bloque?
        if (customFee != currentFee) {
            poolManager.updateDynamicLPFee(key, customFee);
            // emit FeeAdjusted(poolAddress, currentFee, customFee);
        }

        // Generar un swapId único combinando la dirección del pool y el swapNonce
        // [@mevquant]: Igual aqui añadir algo de "salt" como el block.number / timestamp ?????????? [future block same nonce]
        bytes32 swapId = keccak256(abi.encodePacked(poolAddress, swapNonce));
        swapNonce += 1; // Incrementar el nonce para el siguiente swap

        // Almacenar el contexto del swap para ajustes posteriores en 'afterSwap'
        swapContexts[swapId] = SwapContext({
            initialAmountSpecified: params.amountSpecified,
            initialGasPrice: tx.gasprice,
            fee: customFee,
            timestamp: block.timestamp,
            volatility: marketDataByPool[poolAddress].volatility,
            liquidity: marketDataByPool[poolAddress].liquidity
        });

        // Crear BeforeSwapDelta (sin ajuste en este ejemplo)
        customDelta = BeforeSwapDeltaLibrary.ZERO_DELTA;

        // Retornar el selector de la función, el delta personalizado y la tarifa calculada
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
 * @notice Función que se ejecuta después de un swap.
 *         Actualiza el promedio móvil del precio del gas y realiza ajustes post-swap.
 * @param sender Dirección que llama al hook (PoolManager).
 * @param key Información clave del pool.
 * @param params Parámetros del swap.
 * @param actualDelta Delta real del swap.
 * @param data Datos adicionales (no utilizados).
 * @return selector Selector de la función.
 * @return adjustment Ajuste post-swap (no utilizado en este ejemplo).
 */
// [@mevquant]: Igual aqui es buena idea solo guardar la 30d EMA de la IV
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
        //@audit => Research no found
        //import {PoolKey} from "v4-core/types/PoolKey.sol";
        // address poolAddress = address(key.pool);
        address poolAddress;

        // Generar el swapId correspondiente al swap actual usando 'swapNonce - 1'
        bytes32 swapId = keccak256(abi.encodePacked(poolAddress, swapNonce - 1));
        SwapContext memory context = swapContexts[swapId];

        // Validar que el contexto del swap existe
        require(context.timestamp != 0, "Swap context not found");

        // Calcular ajuste del fee basado en la diferencia del precio del gas, slippage y cambios en volatilidad y liquidez
        adjustment = calculateAdjustment(context, actualDelta, poolAddress);

        // Eliminar el contexto del swap para liberar almacenamiento y evitar referencias futuras
        delete swapContexts[swapId];

        // Emitir evento de ajuste post-swap
        // emit SwapAdjusted(poolAddress, adjustment);

        // Actualizar el promedio móvil del gas price con el precio del gas de este swap
        updateMovingAverage();

        // Retornar el selector de la función y el ajuste calculado
        return (this.afterSwap.selector, adjustment);
    }

    /**
     * @notice Calcula la tarifa personalizada basada en múltiples factores: volatilidad, volumen, tamaño del swap, liquidez y precio del gas.
     * @param poolAddress Dirección del pool.
     * @param amountSpecified Cantidad especificada del swap.
     * @return fee Tarifa personalizada en base 10_000 (e.g., 3000 = 30%) 
     */
     //[@mevquant] Q, no sería: 10_000 = 100%, 1_000 = 10%, 100 = 1%, 10 = 0.1%, 1 = 0.01%.
    function calculateCustomFee(address poolAddress, int256 amountSpecified)
        internal
        view
        returns (uint24 fee)
    {
        fee = BASE_FEE;
        MarketData memory data = marketDataByPool[poolAddress];

        // Ajustar por volatilidad: incrementa la tarifa proporcionalmente a la volatilidad
        //@audit => change
        // fee = (fee * (10000 + data.volatility)) / 10000;
        fee = uint24((uint256(fee) * (10000 + data.volatility)) / 10000);

        // Ajustar por volumen de transacciones
        if (data.volume > highVolumeThreshold) {
            fee = (fee * 90) / 100; // Reducir 10% si el volumen es alto
        } else if (data.volume < lowVolumeThreshold) {
            fee = (fee * 110) / 100; // Aumentar 10% si el volumen es bajo
        }

        // Ajustar por tamaño del swap
        if (isLargeSwap(amountSpecified)) {
            fee = (fee * 120) / 100; // Aumentar un 20% para swaps grandes
        }

        // Ajustar por liquidez
        if (data.liquidity < lowLiquidityThreshold) {
            fee = (fee * 150) / 100; // Aumentar un 50% en baja liquidez
        }

        // Ajustar por precio del gas utilizando el EMA
        uint256 gasPriceDifference = calculateGasPriceDifference();
        if (gasPriceDifference > gasPriceThreshold) {
            if (tx.gasprice > movingAverageGasPrice) {
                fee = (fee * 80) / 100; // Reducir un 20% si el gas es significativamente más alto
            } else {
                fee = (fee * 120) / 100; // Aumentar un 20% si el gas es significativamente más bajo
            }
        }

        // Asegurar que la tarifa final esté dentro de los límites establecidos
        fee = uint24(min(max(uint256(fee), MIN_FEE), MAX_FEE));

        return fee;
    }

    /**
     * @notice Calcula el ajuste sobre la fee post-swap basado en varios factores: diferencia del precio del gas, slippage y cambios en volatilidad y liquidez.
     * @param context Contexto del swap almacenado en 'swapContexts'.
     * @param actualDelta Delta real del swap.
     * @param poolAddress Dirección del pool.
     * @return adjustment Ajuste calculado (puede ser positivo o negativo).
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
        // Diferencia del precio del gas entre el swap actual y el promedio
        int256 gasPriceDifference = int256(tx.gasprice) - int256(context.initialGasPrice);
        //@audit => change
        // int128 baseAdjustment = int128((gasPriceDifference * int256(context.fee)) / 1e9);
        int128 baseAdjustment = int128((gasPriceDifference * int256(uint256(context.fee))) / 1e9);

        // Cálculo de slippage: diferencia entre el monto real y el especificado
        int256 actualAmount = int256(actualDelta.amount0()) + int256(actualDelta.amount1());
        int256 slippage = actualAmount - context.initialAmountSpecified;
        int128 slippageAdjustment = int128(slippage / 1000); // 0.1% del slippage

        // Ajuste por cambios en volatilidad y liquidez desde el inicio del swap
        MarketData memory currentData = marketDataByPool[poolAddress];
        int256 volatilityChange = int256(currentData.volatility) - int256(context.volatility);
        int256 liquidityChange = int256(currentData.liquidity) - int256(context.liquidity);

        // Inicializar ajuste adicional
        int128 marketConditionAdjustment = 0;

        // Ajustar por volatilidad si ha habido cambios
        if (volatilityChange != 0) {
            // Ajustar la tarifa proporcionalmente a la diferencia de volatilidad
            //@audit => change
            // marketConditionAdjustment += int128((volatilityChange * int256(context.fee)) / 10000);
            marketConditionAdjustment += int128((volatilityChange * int256(uint256(context.fee))) / 10000);

        }

        // Ajustar por liquidez si ha habido cambios
        if (liquidityChange != 0) {
            // Ajustar la tarifa proporcionalmente a la diferencia de liquidez (escala grande para evitar overflows)
            //@audit => change
            // marketConditionAdjustment += int128((liquidityChange * int256(context.fee)) / 1e22);
            marketConditionAdjustment += int128((liquidityChange * int256(uint256(context.fee))) / 1e22);

        }

        // Sumar todos los ajustes para obtener el ajuste total
        adjustment = baseAdjustment + slippageAdjustment + marketConditionAdjustment;
    }

    /**
     * @notice Actualiza el Promedio Móvil Exponencial (EMA) del precio del gas.
     *         Incorporando el precio del gas actual con un factor de suavizado.
     */
    function updateMovingAverage() internal {
        uint128 currentGasPrice = uint128(tx.gasprice);
        if (movingAverageGasPrice == 0) {
            // Si el EMA no está inicializado, inicializarlo con el precio del gas actual
            initializeEMA(currentGasPrice);
        } else {
            // Calcular el nuevo EMA con el precio del gas actual
            movingAverageGasPrice =
                ((currentGasPrice * emaSmoothingFactor) + (movingAverageGasPrice * (emaPrecisionDivider - emaSmoothingFactor))) /
                emaPrecisionDivider;
        }
    }

    /**
     * @notice Calcula la diferencia porcentual entre el precio del gas actual y el promedio móvil.
     * @return gasPriceDifference Diferencia porcentual (%).
     */
    function calculateGasPriceDifference() internal view returns (uint256 gasPriceDifference) {
        // [@mevquant]: Aqui por ejemplo tenemos tx.gasprice, tendria sentido mirar el medio del bloque?
        uint128 gasPrice = uint128(tx.gasprice);
        if (movingAverageGasPrice == 0) return 0; // Evitar división por cero

        uint256 difference;
        if (gasPrice > movingAverageGasPrice) {
            // Calcular diferencia porcentual cuando el gasPrice es mayor que el promedio
            difference = ((gasPrice - movingAverageGasPrice) * 100) / movingAverageGasPrice;
        } else {
            // Calcular diferencia porcentual cuando el gasPrice es menor que el promedio
            difference = ((movingAverageGasPrice - gasPrice) * 100) / movingAverageGasPrice;
        }

        gasPriceDifference = difference;
    }

    /**
     * @notice Verifica si el swap es considerado grande basado en el tamaño especificado.
     * @param amountSpecified Cantidad especificada del swap.
     * @return bool Indicador de si es un swap grande.
     */
    function isLargeSwap(int256 amountSpecified) internal view returns (bool) {
        // Considera un swap grande si el monto especificado es mayor a la mitad del tamaño máximo del swap
        //@audit => change
        // return abs(amountSpecified) > (int256(maxSwapSize) / 2);
        return uint256(abs(amountSpecified)) > (maxSwapSize / 2);

    }

    /**
     * @notice Calcula el valor absoluto de un número entero.
     * @param x Número entero.
     * @return absValue Valor absoluto de x.
     */
    function abs(int256 x) internal pure returns (uint256 absValue) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    /**
     * @notice Retorna el mínimo de dos números.
     * @param a Primer número.
     * @param b Segundo número.
     * @return minValue Valor mínimo entre a y b.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256 minValue) {
        return a < b ? a : b;
    }

    /**
     * @notice Retorna el máximo de dos números.
     * @param a Primer número.
     * @param b Segundo número.
     * @return maxValue Valor máximo entre a y b.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256 maxValue) {
        return a > b ? a : b;
    }

    /**
     * @notice Actualiza los datos de mercado usando oráculos reales de Chainlink.
     * @param poolAddress Dirección del pool.
     */
    function updateMarketData(address poolAddress) internal {
        // Obtener los nuevos datos de mercado desde los oráculos
        MarketData memory newData = fetchMarketData(poolAddress);

        // Almacenar los nuevos datos de mercado en el mapeo correspondiente al pool
        marketDataByPool[poolAddress] = newData;

        // Emitir el evento 'MarketDataUpdated' con la nueva información
        // emit MarketDataUpdated(
        //     poolAddress,
        //     newData.volatility,
        //     newData.liquidity,
        //     newData.volume,
        //     newData.lastUpdateTimestamp
        // );
    }

    /**
     * @notice Obtiene los datos de mercado desde los oráculos de Chainlink.
     * @param poolAddress Dirección del pool.
     * @return data Estructura con los datos de mercado actualizados.
     */
function fetchMarketData(address poolAddress) internal view returns (MarketData memory data) {

    //@audit => TODO in BREVIS ?
    // Obtener volatilidad desde el oráculo de volatilidad de Chainlink
    (, int256 volatilityPrice, , uint256 volatilityUpdatedAt, ) = volatilityOracle.latestRoundData();
    uint256 v_volatility = uint256(volatilityPrice); // Suponiendo que el oráculo retorna volatilidad en base 10000

    //@audit => add
    // Obtener volatilidad realizada desde chainlink
    // https://docs.chain.link/data-feeds/rates-feeds/addresses?network=ethereum&page=1
    (, int volatility,,,) = realizedVolatility.latestRoundData();
    int r_volatility = volatility; // Corregido: no es necesaria la conversión

    //@audit => add
    // Obtener Price Feeds
    // https://docs.chain.link/data-feeds/price-feeds/addresses?network=ethereum&page=1
    (, int price, , ,) = priceFeed.latestRoundData();
    // No es necesario convertir price, ya es int

    //@audit TODO - => gamma
    // Obtener liquidez desde el oráculo de liquidez de Chainlink
    (, int256 liquidityPrice, , uint256 liquidityUpdatedAt, ) = liquidityOracle.latestRoundData();
    uint256 liquidity = uint256(liquidityPrice); // Supuesto: liquidez en tokens (con decimal 18)

    //@audit TODO => 
    // Obtener volumen desde el oráculo de volumen de Chainlink
    (, int256 volumePrice, , uint256 volumeUpdatedAt, ) = volumeOracle.latestRoundData();
    uint256 volume = uint256(volumePrice); // Supuesto: volumen en tokens (con decimal 18)

    // Crear la estructura 'MarketData' con los valores obtenidos
    //@audit => TODO add marketdata
    data = MarketData({
        volatility: uint256(r_volatility), // Asumiendo que MarketData.volatility es uint256
        liquidity: liquidity,
        volume: volume,
        lastUpdateTimestamp: block.timestamp
    });
}


}