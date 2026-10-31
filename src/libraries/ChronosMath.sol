// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ChronosMath
/// @notice High-precision fixed point math, Babylonian square root, and AMM/TWAMM execution curves
library ChronosMath {
    error MathOverflow();
    error ZeroDenominator();
    error InsufficientReserves();
    error InsufficientInputAmount();
    error InsufficientOutputAmount();

    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS_DIVISOR = 10000;

    /// @notice Returns minimum of two numbers
    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x < y ? x : y;
    }

    /// @notice Returns maximum of two numbers
    function max(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x > y ? x : y;
    }

    /// @notice Babylonian method for integer square root
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    /// @notice Multiply two Wad (18 decimals) numbers with rounding
    function mulWad(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y + (WAD / 2)) / WAD;
    }

    /// @notice Divide two Wad (18 decimals) numbers with rounding
    function divWad(uint256 x, uint256 y) internal pure returns (uint256) {
        if (y == 0) revert ZeroDenominator();
        return (x * WAD + (y / 2)) / y;
    }

    /// @notice Multiply two Ray (27 decimals) numbers with rounding
    function mulRay(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y + (RAY / 2)) / RAY;
    }

    /// @notice Divide two Ray (27 decimals) numbers with rounding
    function divRay(uint256 x, uint256 y) internal pure returns (uint256) {
        if (y == 0) revert ZeroDenominator();
        return (x * RAY + (y / 2)) / y;
    }

    /// @notice Given an input amount and pool reserves, returns the quote for optimal liquidity deposit
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) internal pure returns (uint256 amountB) {
        if (amountA == 0) revert InsufficientInputAmount();
        if (reserveA == 0 || reserveB == 0) revert InsufficientReserves();
        amountB = (amountA * reserveB) / reserveA;
    }

    /// @notice Computes output amount for standard Constant Product swap: (x + dx)(y - dy) = k
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 feeBps)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert InsufficientInputAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientReserves();
        if (feeBps >= BPS_DIVISOR) revert MathOverflow();

        uint256 amountInWithFee = amountIn * (BPS_DIVISOR - feeBps);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * BPS_DIVISOR) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @notice Computes required input amount for desired output in standard Constant Product swap
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint256 feeBps)
        internal
        pure
        returns (uint256 amountIn)
    {
        if (amountOut == 0) revert InsufficientOutputAmount();
        if (reserveIn == 0 || reserveOut == 0 || amountOut >= reserveOut) revert InsufficientReserves();
        if (feeBps >= BPS_DIVISOR) revert MathOverflow();

        uint256 numerator = reserveIn * amountOut * BPS_DIVISOR;
        uint256 denominator = (reserveOut - amountOut) * (BPS_DIVISOR - feeBps);
        amountIn = (numerator / denominator) + 1;
    }

    /// @notice Executes a two-sided simultaneous TWAMM virtual swap across an interval.
    /// @dev Netting is performed where counter-flowing virtual orders clear against each other
    /// at the marginal pool price, and only the residual order trades against AMM pool reserves.
    /// @param xIn Total input amount of token 0 for the interval
    /// @param yIn Total input amount of token 1 for the interval
    /// @param xReserve Initial reserve of token 0
    /// @param yReserve Initial reserve of token 1
    /// @param feeBps Dynamic swap fee in basis points
    /// @return xOut Total token 0 output obtained by token 1 sellers
    /// @return yOut Total token 1 output obtained by token 0 sellers
    /// @return newXReserve Updated reserve 0
    /// @return newYReserve Updated reserve 1
    function computeVirtualSwap(uint256 xIn, uint256 yIn, uint256 xReserve, uint256 yReserve, uint256 feeBps)
        internal
        pure
        returns (uint256 xOut, uint256 yOut, uint256 newXReserve, uint256 newYReserve)
    {
        if (xIn == 0 && yIn == 0) {
            return (0, 0, xReserve, yReserve);
        }

        uint256 multiplier = BPS_DIVISOR - feeBps;

        if (xIn == 0) {
            // Unilateral swap token 1 -> token 0
            xOut = getAmountOut(yIn, yReserve, xReserve, feeBps);
            newXReserve = xReserve - xOut;
            newYReserve = yReserve + yIn;
            return (xOut, 0, newXReserve, newYReserve);
        }

        if (yIn == 0) {
            // Unilateral swap token 0 -> token 1
            yOut = getAmountOut(xIn, xReserve, yReserve, feeBps);
            newXReserve = xReserve + xIn;
            newYReserve = yReserve - yOut;
            return (0, yOut, newXReserve, newYReserve);
        }

        uint256 xInNet = (xIn * multiplier) / BPS_DIVISOR;
        uint256 yInNet = (yIn * multiplier) / BPS_DIVISOR;

        // Bilateral cross: compare value of xInNet vs yInNet at current reserve ratio without premature division
        uint256 valX = (xIn * multiplier * yReserve) / BPS_DIVISOR;
        uint256 valY = (yIn * multiplier * xReserve) / BPS_DIVISOR;

        if (valX == valY) {
            // Exact balance: 100% netting with zero pool impact
            xOut = xInNet;
            yOut = yInNet;
            newXReserve = xReserve + xIn - xOut;
            newYReserve = yReserve + yIn - yOut;
        } else if (valX > valY) {
            // Excess token 0: token 1 sellers are fully matched by a slice of token 0 sellers
            uint256 xCrossed = valY / yReserve;
            uint256 xResidual = xInNet > xCrossed ? xInNet - xCrossed : 0;

            xOut = xCrossed;
            uint256 poolYOut = 0;
            if (xResidual > 0) {
                uint256 currentY = yReserve;
                uint256 currentX = xReserve;
                uint256 num = xResidual * currentY;
                uint256 den = currentX + xResidual;
                poolYOut = num / den;
            }
            yOut = yInNet + poolYOut;

            newXReserve = xReserve + xIn - xOut;
            newYReserve = yReserve + yIn - yOut;
        } else {
            // Excess token 1: token 0 sellers are fully matched by a slice of token 1 sellers
            uint256 yCrossed = valX / xReserve;
            uint256 yResidual = yInNet > yCrossed ? yInNet - yCrossed : 0;

            yOut = yCrossed;
            uint256 poolXOut = 0;
            if (yResidual > 0) {
                uint256 currentX = xReserve;
                uint256 currentY = yReserve;
                uint256 num = yResidual * currentX;
                uint256 den = currentY + yResidual;
                poolXOut = num / den;
            }
            xOut = xInNet + poolXOut;

            newXReserve = xReserve + xIn - xOut;
            newYReserve = yReserve + yIn - yOut;
        }
    }
}
