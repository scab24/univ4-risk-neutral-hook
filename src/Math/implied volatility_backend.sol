// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.19;

// // Import ABDKMath64x64 library from GitHub
// import "abdk-libraries-solidity/ABDKMath64x64.sol";

// /**
//  * @title VolatilityCalculator
//  * @notice Contract to calculate implied volatility and drift based on logarithmic returns.
//  */
// contract VolatilityCalculator {
//     using ABDKMath64x64 for int128;
//     using ABDKMath64x64 for uint256;

//     // Number of logarithmic returns entered
//     uint256 public count;

//     // Accumulated mean in 64.64 fixed-point format
//     int128 public mean;

//     // Accumulated variance (M2) in 64.64 fixed-point format
//     int128 public M2;

//     // Maximum number of allowed returns
//     uint256 public constant MAX_RETURNS = 1000;

//     // Event emitted when a new return is added
//     event LogReturnAdded(int128 logReturn, uint256 newCount);

//     // Event emitted when volatility and drift are calculated
//     event VolatilityAndDriftCalculated(int128 sigma, int128 drift);

//     /**
//      * @notice Calculates the hyperbolic cosine of x.
//      * @param x Value in 64.64 fixed-point format.
//      * @return cosh_x Hyperbolic cosine of x in 64.64 fixed-point format.
//      */
//     function cosh(int128 x) internal pure returns (int128) {
//         // e^x
//         int128 expx = ABDKMath64x64.exp(x);
//         // e^-x
//         int128 expNegx = ABDKMath64x64.exp(ABDKMath64x64.neg(x));
//         // (e^x + e^-x) / 2
//         return ABDKMath64x64.div(ABDKMath64x64.add(expx, expNegx), ABDKMath64x64.fromUInt(2));
//     }

//     /**
//      * @notice Calculates the natural logarithm of x.
//      * @param x Value in 64.64 fixed-point format.
//      * @return ln_x Natural logarithm of x in 64.64 fixed-point format.
//      */
//     function naturalLog(int128 x) internal pure returns (int128) {
//         return ABDKMath64x64.ln(x);
//     }

//     /**
//      * @notice Calculates the square root of x.
//      * @param x Value in 64.64 fixed-point format.
//      * @return sqrt_x Square root of x in 64.64 fixed-point format.
//      */
//     function sqrt(int128 x) internal pure returns (int128) {
//         return ABDKMath64x64.sqrt(x);
//     }

//     /**
//      * @notice Adds a new logarithmic return and updates the mean and variance.
//      * @param logReturn Logarithmic return in 64.64 fixed-point format.
//      */
//     function addLogReturn(int128 logReturn) external /* onlyOwner */ {
//         require(count < MAX_RETURNS, "Maximum number of returns reached");
//         count += 1;

//         if (count == 1) {
//             mean = logReturn;
//             M2 = ABDKMath64x64.fromInt(0); // variance undefined for 1 data point
//             emit LogReturnAdded(logReturn, count);
//             return;
//         }

//         // Welford's Algorithm
//         int128 delta = logReturn - mean;
//         mean = mean + ABDKMath64x64.div(delta, ABDKMath64x64.fromUInt(count));
//         int128 delta2 = logReturn - mean;
//         M2 = ABDKMath64x64.add(M2, ABDKMath64x64.mul(delta, delta2));

//         emit LogReturnAdded(logReturn, count);
//     }

//     /**
//      * @notice Calculates the implied volatility sigma and drift u.
//      * @param u Drift of the underlying asset (u) in 64.64 fixed-point format.
//      * @return sigma Implied volatility in 64.64 fixed-point format.
//      * @return drift Calculated drift in 64.64 fixed-point format.
//      */
//     function calculateSigmaAndDrift(int128 u) external /* onlyOwner */ returns (int128 sigma, int128 drift) {
//         require(count >= 2, "At least 2 returns are required to calculate variance");

//         // Calculate variance: variance = M2 / (n - 1)
//         int128 variance = ABDKMath64x64.div(M2, ABDKMath64x64.fromUInt(count - 1));

//         // Calculate the square root of variance (std dev)
//         int128 stdDev = sqrt(variance);

//         // Calculate sigma = stdDev * sqrt(252)
//         // sqrt(252) ≈ 15.8745
//         // In 64.64 fixed-point, 15.8745 ≈ ABDKMath64x64.fromUInt(15) + 8745/10000 = 15.8745
//         int128 sqrt252 = ABDKMath64x64.add(ABDKMath64x64.fromUInt(15), ABDKMath64x64.divu(8745, 10000)); // Approximation

//         sigma = ABDKMath64x64.mul(stdDev, sqrt252);

//         // Calculate drift u = muPool - (sigma^2 / 2)
//         int128 sigmaSquared = ABDKMath64x64.mul(sigma, sigma);
//         int128 sigmaSquaredOver2 = ABDKMath64x64.div(sigmaSquared, ABDKMath64x64.fromUInt(2));
//         drift = ABDKMath64x64.sub(mean, sigmaSquaredOver2);

//         emit VolatilityAndDriftCalculated(sigma, drift);
//     }

//     /**
//      * @notice Calculates the drift u using the formula:
//      * u = muPool - (sigma^2 / 2)
//      * @param muPool Average return in pool fees during time t (μ_pool) in 64.64 fixed-point format.
//      * @param sigma Implied volatility σ in 64.64 fixed-point format.
//      * @return u Calculated drift in 64.64 fixed-point format.
//      */
//     function calculateDrift(int128 muPool, int128 sigma) public pure returns (int128 u) {
//         // Calculate sigma^2
//         int128 sigmaSquared = ABDKMath64x64.mul(sigma, sigma);

//         // Calculate sigma^2 / 2
//         int128 sigmaSquaredOver2 = ABDKMath64x64.div(sigmaSquared, ABDKMath64x64.fromUInt(2));

//         // Calculate u = muPool - (sigma^2 / 2)
//         u = ABDKMath64x64.sub(muPool, sigmaSquaredOver2);
//     }

//     /**
//      * @notice Gets the mean of the logarithmic returns.
//      * @return mean_64x64 Mean in 64.64 fixed-point format.
//      */
//     function getMean() external view /* onlyOwner */ returns (int128) {
//         return mean;
//     }

//     /**
//      * @notice Gets the accumulated variance.
//      * @return M2_64x64 Accumulated variance in 64.64 fixed-point format.
//      */
//     function getM2() external view /* onlyOwner */ returns (int128) {
//         return M2;
//     }

//     /**
//      * @notice Calculates and returns the implied volatility and drift without storing them.
//      * @param muPool Average return in pool fees during time t (μ_pool) in 64.64 fixed-point format.
//      * @param u Drift of the underlying asset (u) in 64.64 fixed-point format.
//      * @param t Time in years (t), we assume t = 1.
//      * @return sigma Implied volatility in 64.64 fixed-point format.
//      * @return drift Calculated drift in 64.64 fixed-point format.
//      */
//     function computeImpliedVolatilityAndDrift(int128 muPool, int128 u, uint256 t) external pure returns (int128 sigma, int128 drift) {
//         require(t > 0, "Time t must be greater than zero");

//         // Calculate u * t / 2
//         int128 ut = ABDKMath64x64.mul(u, ABDKMath64x64.fromUInt(t));
//         int128 utOver2 = ABDKMath64x64.div(ut, ABDKMath64x64.fromUInt(2));

//         // Calculate cosh(u * t / 2)
//         int128 coshUtOver2 = cosh(utOver2);

//         // Calculate ln(cosh(u * t / 2))
//         int128 lnCoshUtOver2 = naturalLog(coshUtOver2);

//         // Calculate [mu_pool * t - ln(cosh(u * t / 2))]
//         int128 innerExpression = ABDKMath64x64.sub(muPool, lnCoshUtOver2);

//         // Calculate 8 / t
//         int128 eightOverT = ABDKMath64x64.div(ABDKMath64x64.fromUInt(8), ABDKMath64x64.fromUInt(t));

//         // Multiply 8/t * [mu_pool * t - ln(cosh(u * t / 2))]
//         int128 multiplicand = ABDKMath64x64.mul(eightOverT, innerExpression);

//         // Calculate the square root of multiplicand
//         sigma = sqrt(multiplicand);

//         // Calculate drift u = muPool - (sigma^2 / 2)
//         int128 sigmaSquared = ABDKMath64x64.mul(sigma, sigma);
//         int128 sigmaSquaredOver2 = ABDKMath64x64.div(sigmaSquared, ABDKMath64x64.fromUInt(2));
//         drift = ABDKMath64x64.sub(muPool, sigmaSquaredOver2);
//     }
// }