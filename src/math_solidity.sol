// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Importa la biblioteca ABDKMath64x64 desde GitHub
import "abdk-libraries-solidity/ABDKMath64x64.sol";

/**
 * @title VolatilityCalculator
 * @notice Contrato para calcular la volatilidad implícita y drift basado en retornos logarítmicos.
 * Incluye el cálculo de logReturn utilizando una aproximación de la serie de Taylor.
 */
contract VolatilityCalculator {
    using ABDKMath64x64 for int128;
    using ABDKMath64x64 for uint256;

    // Número de retornos logarítmicos ingresados
    uint256 public count;

    // Media acumulada en formato 64.64 fija
    int128 public mean;

    // Varianza acumulada (M2) en formato 64.64 fija
    int128 public M2;

    // Máximo número de retornos permitidos
    uint256 public constant MAX_RETURNS = 1000;

    // Array para almacenar precios del activo
    uint256[] public prices;

    // Array para almacenar retornos logarítmicos en formato 64.64 fija
    int128[] public logReturns;

    // Eventos para monitorear acciones
    event PriceAdded(uint256 price, uint256 newCount);
    event LogReturnAdded(int128 logReturn, uint256 newCount);
    event VolatilityAndDriftCalculated(int128 sigma, int128 drift);

    /**
     * @notice Calcula el coseno hiperbólico de x.
     * @param x Valor en formato 64.64 fija.
     * @return cosh_x Coseno hiperbólico de x en formato 64.64 fija.
     */
    function cosh(int128 x) internal pure returns (int128) {
        // e^x
        int128 expx = ABDKMath64x64.exp(x);
        // e^-x
        int128 expNegx = ABDKMath64x64.exp(ABDKMath64x64.neg(x));
        // (e^x + e^-x) / 2
        return ABDKMath64x64.div(ABDKMath64x64.add(expx, expNegx), ABDKMath64x64.fromUInt(2));
    }

    /**
     * @notice Calcula el logaritmo natural de x utilizando la biblioteca ABDKMath64x64.
     * @param x Valor en formato 64.64 fija.
     * @return ln_x Logaritmo natural de x en formato 64.64 fija.
     */
    function naturalLog(int128 x) internal pure returns (int128) {
        return ABDKMath64x64.ln(x);
    }

    /**
     * @notice Calcula la raíz cuadrada de x utilizando la biblioteca ABDKMath64x64.
     * @param x Valor en formato 64.64 fija.
     * @return sqrt_x Raíz cuadrada de x en formato 64.64 fija.
     */
    function sqrt(int128 x) internal pure returns (int128) {
        return ABDKMath64x64.sqrt(x);
    }

    /**
     * @notice Calcula el logaritmo natural de x utilizando una aproximación de la serie de Taylor.
     * @param x Valor para el cual se calculará ln(x) en formato 64.64 fija.
     * @return ln_x Logaritmo natural aproximado de x en formato 64.64 fija.
     */
    function approximateLn(int128 x) internal pure returns (int128 ln_x) {
        require(x > 0, "x debe ser positivo");

        // Número de términos de la serie de Taylor
        uint256 terms = 6;

        // Normalización: encontrar k tal que x = y * 2^k, donde y está en [0.5, 1.5]
        int256 k = 0; // Contador para el exponente de 2
        int128 y = x;

        // Límites para la normalización
        int128 onePointFive = ABDKMath64x64.divu(3, 2); // 1.5 en formato 64.64 fija
        int128 zeroPointFive = ABDKMath64x64.divu(1, 2); // 0.5 en formato 64.64 fija

        // Ajustar y y k para que y esté en [0.5, 1.5]
        while (y > onePointFive) {
            y = y.div(ABDKMath64x64.fromUInt(2)); // Dividir y por 2
            k += 1;
        }

        while (y < zeroPointFive) {
            y = y.mul(ABDKMath64x64.fromUInt(2)); // Multiplicar y por 2
            k -= 1;
        }

        // Ahora, y está en [0.5, 1.5]
        // Podemos escribir y = 1 + z, donde z está en [-0.5, 0.5]
        int128 one = ABDKMath64x64.fromUInt(1);
        int128 z = y.sub(one);

        // Inicializar ln_x con el primer término de la serie de Taylor
        ln_x = z;

        // Variables para la expansión de la serie
        int128 term = z; // Término actual inicializado a z^1 / 1
        int128 z_power = z; // z elevado a la potencia n
        int128 sign = ABDKMath64x64.fromInt(-1); // Signo alternante inicia en negativo

        // Calcular la suma de la serie de Taylor
        for (uint256 n = 2; n <= terms; n++) {
            // Calcular z_power = z^n
            z_power = z_power.mul(z);

            // term = z^n / n
            term = z_power.div(ABDKMath64x64.fromUInt(n));

            // Alternar el signo para cada término
            term = term.mul(sign);

            // Agregar el término al resultado
            ln_x = ln_x.add(term);

            // Cambiar el signo para el siguiente término
            sign = sign.neg();
        }

        // Agregar ln(2^k) = k * ln(2)
        // ln(2) ≈ 0.69314718056 en decimal
        int128 LN2 = 0xB17217F7D1CF79AB; // ln(2) en formato 64.64 fija
        int128 kLn2 = ABDKMath64x64.fromInt(k).mul(LN2);

        ln_x = ln_x.add(kLn2);
    }

    /**
     * @notice Agrega un nuevo precio y calcula el retorno logarítmico respecto al precio anterior.
     * @param newPrice Precio del activo en el nuevo periodo (sin decimales).
     */
    function addPrice(uint256 newPrice) external /* onlyOwner */ {
        require(prices.length - 1 < MAX_RETURNS, "Excede el maximo de retornos");

        // Agregar el nuevo precio al array
        prices.push(newPrice);
        emit PriceAdded(newPrice, prices.length);

        // Si es el primer precio, no hay retorno que calcular
        if (prices.length == 1) {
            return;
        }

        // Obtener el precio anterior y el actual
        uint256 prevPrice = prices[prices.length - 2];
        uint256 currentPrice = prices[prices.length - 1];

        // Convertir los precios a formato 64.64 fija
        int128 pi = ABDKMath64x64.fromUInt(currentPrice);
        int128 pi_prev = ABDKMath64x64.fromUInt(prevPrice);

        // Calcular la relación: Pi / P_{i-1}
        int128 ratio = pi.div(pi_prev);

        // Calcular ln(ratio) usando la aproximación de la serie de Taylor
        int128 logReturn = approximateLn(ratio);

        // Agregar el retorno al cálculo estadístico
        _addLogReturn_internal(logReturn);
    }

    /**
     * @notice Agrega un nuevo retorno logarítmico y actualiza la media y varianza.
     * @param logReturn Retorno logarítmico en formato 64.64 fija.
     */
    function addLogReturn(int128 logReturn) external /* onlyOwner */ {
        require(count < MAX_RETURNS, "Se ha alcanzado el maximo de retornos");
        _addLogReturn_internal(logReturn);
    }

    /**
     * @notice Función interna para agregar un retorno logarítmico y actualizar estadísticas.
     * @param logReturn Retorno logarítmico en formato 64.64 fija.
     */
    function _addLogReturn_internal(int128 logReturn) internal {
        logReturns.push(logReturn);
        count += 1;

        if (count == 1) {
            mean = logReturn;
            M2 = ABDKMath64x64.fromInt(0); // varianza no definida para 1 dato
            emit LogReturnAdded(logReturn, count);
            return;
        }

        // Algoritmo de Welford para actualizar la media y M2
        int128 delta = logReturn.sub(mean);
        mean = mean.add(delta.div(ABDKMath64x64.fromUInt(count)));
        int128 delta2 = logReturn.sub(mean);
        M2 = M2.add(delta.mul(delta2));

        emit LogReturnAdded(logReturn, count);
    }

    /**
     * @notice Calcula la volatilidad implícita sigma y el drift u.
     * @return sigma Volatilidad implícita en formato 64.64 fija.
     * @return drift Drift calculado en formato 64.64 fija.
     */
    function calculateSigmaAndDrift() external /* onlyOwner */ returns (int128 sigma, int128 drift) {
        require(count >= 2, "Se requieren al menos 2 retornos para calcular varianza");

        // Calcular varianza: varianza = M2 / (n - 1)
        int128 variance = M2.div(ABDKMath64x64.fromUInt(count - 1));

        // Calcular la desviación estándar (std dev) = sqrt(varianza)
        int128 stdDev = sqrt(variance);

        // Anualizar la desviación estándar: sigma = stdDev * sqrt(252)
        // sqrt(252) ≈ 15.87401
        int128 sqrt252 = ABDKMath64x64.fromUInt(15).add(ABDKMath64x64.divu(87401, 100000)); // Aproximación

        sigma = stdDev.mul(sqrt252);

        // Calcular drift u = mean - (sigma^2 / 2)
        int128 sigmaSquared = sigma.mul(sigma);
        int128 sigmaSquaredOver2 = sigmaSquared.div(ABDKMath64x64.fromUInt(2));
        drift = mean.sub(sigmaSquaredOver2);

        emit VolatilityAndDriftCalculated(sigma, drift);
    }

    /**
     * @notice Calcula el drift u usando la fórmula:
     * u = muPool - (sigma^2 / 2)
     * @param muPool Retorno medio en fees de la pool durante el tiempo t (μ_pool) en formato 64.64 fija.
     * @param sigma Volatilidad implícita σ en formato 64.64 fija.
     * @return u Drift calculado en formato 64.64 fija.
     */
    function calculateDrift(int128 muPool, int128 sigma) public pure returns (int128 u) {
        // Calcular sigma^2
        int128 sigmaSquared = sigma.mul(sigma);

        // Calcular sigma^2 / 2
        int128 sigmaSquaredOver2 = sigmaSquared.div(ABDKMath64x64.fromUInt(2));

        // Calcular u = muPool - (sigma^2 / 2)
        u = muPool.sub(sigmaSquaredOver2);
    }

    /**
     * @notice Calcula y devuelve la volatilidad implícita y drift sin almacenarlos.
     * @param muPool Retorno medio en fees de la pool durante el tiempo t (μ_pool) en formato 64.64 fija.
     * @param u Drift del activo subyacente (u) en formato 64.64 fija.
     * @param t Tiempo en años (t), asumimos t = 1.
     * @return sigma Volatilidad implícita en formato 64.64 fija.
     * @return drift Drift calculado en formato 64.64 fija.
     */
    function computeImpliedVolatilityAndDrift(int128 muPool, int128 u, uint256 t) external pure returns (int128 sigma, int128 drift) {
        require(t > 0, "Tiempo t debe ser mayor que cero");

        // Calcular u * t / 2
        int128 ut = u.mul(ABDKMath64x64.fromUInt(t));
        int128 utOver2 = ut.div(ABDKMath64x64.fromUInt(2));

        // Calcular cosh(u * t / 2)
        int128 coshUtOver2 = cosh(utOver2);

        // Calcular ln(cosh(u * t / 2)) utilizando la aproximación de ln(x)
        int128 lnCoshUtOver2 = approximateLn(coshUtOver2);

        // Calcular [mu_pool * t - ln(cosh(u * t / 2))]
        int128 muPoolTimesT = muPool.mul(ABDKMath64x64.fromUInt(t));
        int128 innerExpression = muPoolTimesT.sub(lnCoshUtOver2);

        // Calcular 8 / t
        int128 eightOverT = ABDKMath64x64.fromUInt(8).div(ABDKMath64x64.fromUInt(t));

        // Multiplicar 8/t * [mu_pool * t - ln(cosh(u * t / 2))]
        int128 multiplicand = eightOverT.mul(innerExpression);

        // Calcular la raíz cuadrada de multiplicand
        sigma = sqrt(multiplicand);

        // Calcular drift u = muPool - (sigma^2 / 2)
        int128 sigmaSquared = sigma.mul(sigma);
        int128 sigmaSquaredOver2 = sigmaSquared.div(ABDKMath64x64.fromUInt(2));
        drift = muPool.sub(sigmaSquaredOver2);
    }

    /**
     * @notice Obtiene la media de los retornos logarítmicos.
     * @return mean_64x64 Media en formato 64.64 fija.
     */
    function getMean() external view /* onlyOwner */ returns (int128) {
        return mean;
    }

    /**
     * @notice Obtiene la varianza acumulada (M2).
     * @return M2_64x64 Varianza acumulada en formato 64.64 fija.
     */
    function getM2() external view /* onlyOwner */ returns (int128) {
        return M2;
    }

    /**
     * @notice Obtiene un retorno logarítmico específico por su índice.
     * @param index Índice del retorno logarítmico (empezando desde 0).
     * @return logReturn Retorno logarítmico en formato 64.64 fija.
     */
    function getLogReturn(uint256 index) external view /* onlyOwner */ returns (int128 logReturn) {
        require(index < logReturns.length, "Indice fuera de rango");
        return logReturns[index];
    }

    /**
     * @notice Obtiene todos los retornos logarítmicos.
     * @return allLogReturns Array de retornos logarítmicos en formato 64.64 fija.
     */
    function getAllLogReturns() external view /* onlyOwner */ returns (int128[] memory allLogReturns) {
        return logReturns;
    }
}