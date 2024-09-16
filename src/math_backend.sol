// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Importa la biblioteca ABDKMath64x64 desde GitHub
import "abdk-libraries-solidity/ABDKMath64x64.sol";

/**
 * @title VolatilityCalculator
 * @notice Contrato para calcular la volatilidad implícita y drift basado en retornos logarítmicos.
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

    // Evento emitido cuando se agrega un nuevo retorno
    event LogReturnAdded(int128 logReturn, uint256 newCount);

    // Event emitido cuando se calcula la volatilidad y drift
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
     * @notice Calcula el logaritmo natural de x.
     * @param x Valor en formato 64.64 fija.
     * @return ln_x Logaritmo natural de x en formato 64.64 fija.
     */
    function naturalLog(int128 x) internal pure returns (int128) {
        return ABDKMath64x64.ln(x);
    }

    /**
     * @notice Calcula la raíz cuadrada de x.
     * @param x Valor en formato 64.64 fija.
     * @return sqrt_x Raíz cuadrada de x en formato 64.64 fija.
     */
    function sqrt(int128 x) internal pure returns (int128) {
        return ABDKMath64x64.sqrt(x);
    }

    /**
     * @notice Agrega un nuevo retorno logarítmico y actualiza la media y varianza.
     * @param logReturn Retorno logarítmico en formato 64.64 fija.
     */
    function addLogReturn(int128 logReturn) external /* onlyOwner */ {
        require(count < MAX_RETURNS, "Se ha alcanzado el maximo de retornos");
        count += 1;

        if (count == 1) {
            mean = logReturn;
            M2 = ABDKMath64x64.fromInt(0); // varianza no definida para 1 dato
            emit LogReturnAdded(logReturn, count);
            return;
        }

        // Welford's Algorithm
        int128 delta = logReturn - mean;
        mean = mean + ABDKMath64x64.div(delta, ABDKMath64x64.fromUInt(count));
        int128 delta2 = logReturn - mean;
        M2 = ABDKMath64x64.add(M2, ABDKMath64x64.mul(delta, delta2));

        emit LogReturnAdded(logReturn, count);
    }

    /**
     * @notice Calcula la volatilidad implícita sigma y el drift u.
     * @param u Drift del activo subyacente (u) en formato 64.64 fija.
     * @return sigma Volatilidad implícita en formato 64.64 fija.
     * @return drift Drift calculado en formato 64.64 fija.
     */
    function calculateSigmaAndDrift(int128 u) external /* onlyOwner */ returns (int128 sigma, int128 drift) {
        require(count >= 2, "Se requieren al menos 2 retornos para calcular varianza");

        // Calcular varianza: varianza = M2 / (n - 1)
        int128 variance = ABDKMath64x64.div(M2, ABDKMath64x64.fromUInt(count - 1));

        // Calcular la raíz cuadrada de la varianza (std dev)
        int128 stdDev = sqrt(variance);

        // Calcular sigma = stdDev * sqrt(252)
        // sqrt(252) ≈ 15.8745
        // En 64.64 fija, 15.8745 ≈ ABDKMath64x64.fromUInt(15) + 8745/10000 = 15.8745
        int128 sqrt252 = ABDKMath64x64.add(ABDKMath64x64.fromUInt(15), ABDKMath64x64.divu(8745, 10000)); // Aproximación

        sigma = ABDKMath64x64.mul(stdDev, sqrt252);

        // Calcular drift u = muPool - (sigma^2 / 2)
        int128 sigmaSquared = ABDKMath64x64.mul(sigma, sigma);
        int128 sigmaSquaredOver2 = ABDKMath64x64.div(sigmaSquared, ABDKMath64x64.fromUInt(2));
        drift = ABDKMath64x64.sub(mean, sigmaSquaredOver2);

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
        int128 sigmaSquared = ABDKMath64x64.mul(sigma, sigma);

        // Calcular sigma^2 / 2
        int128 sigmaSquaredOver2 = ABDKMath64x64.div(sigmaSquared, ABDKMath64x64.fromUInt(2));

        // Calcular u = muPool - (sigma^2 / 2)
        u = ABDKMath64x64.sub(muPool, sigmaSquaredOver2);
    }

    /**
     * @notice Obtiene la media de los retornos logarítmicos.
     * @return mean_64x64 Media en formato 64.64 fija.
     */
    function getMean() external view /* onlyOwner */ returns (int128) {
        return mean;
    }

    /**
     * @notice Obtiene la varianza acumulada.
     * @return M2_64x64 Varianza acumulada en formato 64.64 fija.
     */
    function getM2() external view /* onlyOwner */ returns (int128) {
        return M2;
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
        int128 ut = ABDKMath64x64.mul(u, ABDKMath64x64.fromUInt(t));
        int128 utOver2 = ABDKMath64x64.div(ut, ABDKMath64x64.fromUInt(2));

        // Calcular cosh(u * t / 2)
        int128 coshUtOver2 = cosh(utOver2);

        // Calcular ln(cosh(u * t / 2))
        int128 lnCoshUtOver2 = naturalLog(coshUtOver2);

        // Calcular [mu_pool * t - ln(cosh(u * t / 2))]
        int128 innerExpression = ABDKMath64x64.sub(muPool, lnCoshUtOver2);

        // Calcular 8 / t
        int128 eightOverT = ABDKMath64x64.div(ABDKMath64x64.fromUInt(8), ABDKMath64x64.fromUInt(t));

        // Multiplicar 8/t * [mu_pool * t - ln(cosh(u * t / 2))]
        int128 multiplicand = ABDKMath64x64.mul(eightOverT, innerExpression);

        // Calcular la raíz cuadrada de multiplicand
        sigma = sqrt(multiplicand);

        // Calcular drift u = muPool - (sigma^2 / 2)
        int128 sigmaSquared = ABDKMath64x64.mul(sigma, sigma);
        int128 sigmaSquaredOver2 = ABDKMath64x64.div(sigmaSquared, ABDKMath64x64.fromUInt(2));
        drift = ABDKMath64x64.sub(muPool, sigmaSquaredOver2);
    }
}