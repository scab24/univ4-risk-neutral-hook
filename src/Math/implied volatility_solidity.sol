// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Import the ABDKMath64x64 library from GitHub
import "abdk-libraries-solidity/ABDKMath64x64.sol";

/**
 * @title VolatilityCalculator
 * @notice Contract to calculate implied volatility and drift based on logarithmic returns.
 * Includes the calculation of logReturn using a Taylor series approximation.
 */
contract VolatilityCalculator {
    using ABDKMath64x64 for int128;
    using ABDKMath64x64 for uint256;

    // Number of logarithmic returns entered
    uint256 public count;

    // Accumulated mean in 64.64 fixed format
    int128 public mean;

    // Accumulated variance (M2) in 64.64 fixed format
    int128 public M2;

    // Maximum number of allowed returns
    uint256 public constant MAX_RETURNS = 1000;

    // Array to store asset prices
    uint256[] public prices;

    // Array to store logarithmic returns in 64.64 fixed format
    int128[] public logReturns;

    // Events to monitor actions
    event PriceAdded(uint256 price, uint256 newCount);
    event LogReturnAdded(int128 logReturn, uint256 newCount);
    event VolatilityAndDriftCalculated(int128 sigma, int128 drift);

    /**
     * @notice Calculates the hyperbolic cosine of x.
     * @param x Value in 64.64 fixed format.
     * @return cosh_x Hyperbolic cosine of x in 64.64 fixed format.
     */
    function cosh(int128 x) public pure returns (int128) {
        // e^x
        int128 expx = ABDKMath64x64.exp(x);
        // e^-x
        int128 expNegx = ABDKMath64x64.exp(ABDKMath64x64.neg(x));
        // (e^x + e^-x) / 2
        return ABDKMath64x64.div(ABDKMath64x64.add(expx, expNegx), ABDKMath64x64.fromUInt(2));
    }

    /**
     * @notice Calculates the natural logarithm of x using the ABDKMath64x64 library.
     * @param x Value in 64.64 fixed format.
     * @return ln_x Natural logarithm of x in 64.64 fixed format.
     */
    function naturalLog(int128 x) internal pure returns (int128) {
        return ABDKMath64x64.ln(x);
    }

    /**
     * @notice Calculates the square root of x using the ABDKMath64x64 library.
     * @param x Value in 64.64 fixed format.
     * @return sqrt_x Square root of x in 64.64 fixed format.
     */
    function sqrt(int128 x) public pure returns (int128) {
        return ABDKMath64x64.sqrt(x);
    }

    /**
     * @notice Calculates the natural logarithm of x using a Taylor series approximation.
     * @param x Value for which ln(x) will be calculated in 64.64 fixed format.
     * @return ln_x Approximated natural logarithm of x in 64.64 fixed format.
     */
    function approximateLn(int128 x) public pure returns (int128 ln_x) {
        require(x > 0, "x must be positive");

        // Number of terms in the Taylor series
        uint256 terms = 6;

        // Normalization: find k such that x = y * 2^k, where y is in [0.5, 1.5]
        int256 k = 0; // Counter for the exponent of 2
        int128 y = x;

        // Limits for normalization
        int128 onePointFive = ABDKMath64x64.divu(3, 2); // 1.5 in 64.64 fixed format
        int128 zeroPointFive = ABDKMath64x64.divu(1, 2); // 0.5 in 64.64 fixed format

        // Adjust y and k so that y is in [0.5, 1.5]
        while (y > onePointFive) {
            y = y.div(ABDKMath64x64.fromUInt(2)); // Divide y by 2
            k += 1;
        }

        while (y < zeroPointFive) {
            y = y.mul(ABDKMath64x64.fromUInt(2)); // Multiply y by 2
            k -= 1;
        }

        // Now, y is in [0.5, 1.5]
        // We can write y = 1 + z, where z is in [-0.5, 0.5]
        int128 one = ABDKMath64x64.fromUInt(1);
        int128 z = y.sub(one);

        // Initialize ln_x with the first term of the Taylor series
        ln_x = z;

        // Variables for the series expansion
        int128 term = z; // Current term initialized to z^1 / 1
        int128 z_power = z; // z raised to the power n
        int128 sign = ABDKMath64x64.fromInt(-1); // Alternating sign starts negative

        // Calculate the sum of the Taylor series
        for (uint256 n = 2; n <= terms; n++) {
            // Calculate z_power = z^n
            z_power = z_power.mul(z);

            // term = z^n / n
            term = z_power.div(ABDKMath64x64.fromUInt(n));

            // Alternate the sign for each term
            term = term.mul(sign);

            // Add the term to the result
            ln_x = ln_x.add(term);

            // Change the sign for the next term
            sign = sign.neg();
        }

        // Add ln(2^k) = k * ln(2)
        // ln(2) ≈ 0.69314718056 in decimal
        int128 LN2 = 0xB17217F7D1CF79AB; // ln(2) in 64.64 fixed format
        int128 kLn2 = ABDKMath64x64.fromInt(k).mul(LN2);

        ln_x = ln_x.add(kLn2);
    }

    /**
     * @notice Adds a new price and calculates the logarithmic return relative to the previous price.
     * @param newPrice Asset price in the new period (without decimals).
     */
    function addPrice(uint256 newPrice) external /* onlyOwner */ {
        require(prices.length - 1 < MAX_RETURNS, "Exceeds maximum returns");

        // Add the new price to the array
        prices.push(newPrice);
        emit PriceAdded(newPrice, prices.length);

        // If it's the first price, there's no return to calculate
        if (prices.length == 1) {
            return;
        }

        // Get the previous and current prices
        uint256 prevPrice = prices[prices.length - 2];
        uint256 currentPrice = prices[prices.length - 1];

        // Convert prices to 64.64 fixed format
        int128 pi = ABDKMath64x64.fromUInt(currentPrice);
        int128 pi_prev = ABDKMath64x64.fromUInt(prevPrice);

        // Calculate the ratio: Pi / P_{i-1}
        int128 ratio = pi.div(pi_prev);

        // Calculate ln(ratio) using the Taylor series approximation
        int128 logReturn = approximateLn(ratio);

        // Add the return to the statistical calculation
        _addLogReturn_internal(logReturn);
    }

    /**
     * @notice Adds a new logarithmic return and updates the mean and variance.
     * @param logReturn Logarithmic return in 64.64 fixed format.
     */
    function addLogReturn(int128 logReturn) external /* onlyOwner */ {
        require(count < MAX_RETURNS, "Maximum returns reached");
        _addLogReturn_internal(logReturn);
    }

    /**
     * @notice Internal function to add a logarithmic return and update statistics.
     * @param logReturn Logarithmic return in 64.64 fixed format.
     */
    function _addLogReturn_internal(int128 logReturn) internal {
        logReturns.push(logReturn);
        count += 1;

        if (count == 1) {
            mean = logReturn;
            M2 = ABDKMath64x64.fromInt(0); // Variance undefined for 1 data point
            emit LogReturnAdded(logReturn, count);
            return;
        }

        // Welford's algorithm to update mean and M2
        int128 delta = logReturn.sub(mean);
        mean = mean.add(delta.div(ABDKMath64x64.fromUInt(count)));
        int128 delta2 = logReturn.sub(mean);
        M2 = M2.add(delta.mul(delta2));

        emit LogReturnAdded(logReturn, count);
    }

    /**
     * @notice Calculates the implied volatility sigma and drift u.
     * @return sigma Implied volatility in 64.64 fixed format.
     * @return drift Calculated drift in 64.64 fixed format.
     */
    function calculateSigmaAndDrift() external /* onlyOwner */ returns (int128 sigma, int128 drift) {
        require(count >= 2, "At least 2 returns required to calculate variance");

        // Calculate variance: variance = M2 / (n - 1)
        int128 variance = M2.div(ABDKMath64x64.fromUInt(count - 1));

        // Calculate standard deviation (std dev) = sqrt(variance)
        int128 stdDev = sqrt(variance);

        // Annualize the standard deviation: sigma = stdDev * sqrt(252)
        // sqrt(252) ≈ 15.87401
        int128 sqrt252 = ABDKMath64x64.fromUInt(15).add(ABDKMath64x64.divu(87401, 100000)); // Approximation

        sigma = stdDev.mul(sqrt252);

        // Calculate drift u = mean - (sigma^2 / 2)
        int128 sigmaSquared = sigma.mul(sigma);
        int128 sigmaSquaredOver2 = sigmaSquared.div(ABDKMath64x64.fromUInt(2));
        drift = mean.sub(sigmaSquaredOver2);

        emit VolatilityAndDriftCalculated(sigma, drift);
    }

    /**
     * @notice Calculates the drift u using the formula:
     * u = muPool - (sigma^2 / 2)
     * @param muPool Mean return in pool fees over time t (μ_pool) in 64.64 fixed format.
     * @param sigma Implied volatility σ in 64.64 fixed format.
     * @return u Calculated drift in 64.64 fixed format.
     */
    function calculateDrift(int128 muPool, int128 sigma) public pure returns (int128 u) {
        // Calculate sigma^2
        int128 sigmaSquared = sigma.mul(sigma);

        // Calculate sigma^2 / 2
        int128 sigmaSquaredOver2 = sigmaSquared.div(ABDKMath64x64.fromUInt(2));

        // Calculate u = muPool - (sigma^2 / 2)
        u = muPool.sub(sigmaSquaredOver2);
    }

    /**
     * @notice Calculates and returns the implied volatility and drift without storing them.
     * @param muPool Mean return in pool fees over time t (μ_pool) in 64.64 fixed format.
     * @param u Drift of the underlying asset (u) in 64.64 fixed format.
     * @param t Time in years (t), assuming t = 1.
     * @return sigma Implied volatility in 64.64 fixed format.
     * @return drift Calculated drift in 64.64 fixed format.
     */
    function computeImpliedVolatilityAndDrift(int128 muPool, int128 u, uint256 t) external pure returns (int128 sigma, int128 drift) {
        require(t > 0, "Time t must be greater than zero");

        // Calculate u * t / 2
        int128 ut = u.mul(ABDKMath64x64.fromUInt(t));
        int128 utOver2 = ut.div(ABDKMath64x64.fromUInt(2));

        // Calculate cosh(u * t / 2)
        int128 coshUtOver2 = cosh(utOver2);

        // Calculate ln(cosh(u * t / 2)) using the logarithm approximation
        int128 lnCoshUtOver2 = approximateLn(coshUtOver2);

        // Calculate [mu_pool * t - ln(cosh(u * t / 2))]
        int128 muPoolTimesT = muPool.mul(ABDKMath64x64.fromUInt(t));
        int128 innerExpression = muPoolTimesT.sub(lnCoshUtOver2);

        // Calculate 8 / t
        int128 eightOverT = ABDKMath64x64.fromUInt(8).div(ABDKMath64x64.fromUInt(t));

        // Multiply 8/t * [mu_pool * t - ln(cosh(u * t / 2))]
        int128 multiplicand = eightOverT.mul(innerExpression);

        // Calculate the square root of multiplicand
        sigma = sqrt(multiplicand);

        // Calculate drift u = muPool - (sigma^2 / 2)
        int128 sigmaSquared = sigma.mul(sigma);
        int128 sigmaSquaredOver2 = sigmaSquared.div(ABDKMath64x64.fromUInt(2));
        drift = muPool.sub(sigmaSquaredOver2);
    }

    /**
     * @notice Retrieves the mean of the logarithmic returns.
     * @return mean_64x64 Mean in 64.64 fixed format.
     */
    function getMean() external view /* onlyOwner */ returns (int128) {
        return mean;
    }

    /**
     * @notice Retrieves the accumulated variance (M2).
     * @return M2_64x64 Accumulated variance in 64.64 fixed format.
     */
    function getM2() external view /* onlyOwner */ returns (int128) {
        return M2;
    }

    /**
     * @notice Retrieves a specific logarithmic return by its index.
     * @param index Index of the logarithmic return (starting from 0).
     * @return logReturn Logarithmic return in 64.64 fixed format.
     */
    function getLogReturn(uint256 index) external view /* onlyOwner */ returns (int128 logReturn) {
        require(index < logReturns.length, "Index out of range");
        return logReturns[index];
    }

    /**
     * @notice Retrieves all logarithmic returns.
     * @return allLogReturns Array of logarithmic returns in 64.64 fixed format.
     */
    function getAllLogReturns() external view /* onlyOwner */ returns (int128[] memory allLogReturns) {
        return logReturns;
    }
}