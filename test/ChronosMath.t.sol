// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChronosMath} from "../src/libraries/ChronosMath.sol";

contract ChronosMathTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;

    function test_Sqrt_EdgeCases() public pure {
        assertEq(ChronosMath.sqrt(0), 0);
        assertEq(ChronosMath.sqrt(1), 1);
        assertEq(ChronosMath.sqrt(2), 1);
        assertEq(ChronosMath.sqrt(3), 1);
        assertEq(ChronosMath.sqrt(4), 2);
        assertEq(ChronosMath.sqrt(9), 3);
        assertEq(ChronosMath.sqrt(100), 10);
        assertEq(ChronosMath.sqrt(1e18), 1e9);
        assertEq(ChronosMath.sqrt(1e36), 1e18);
    }

    function testFuzz_Sqrt(uint128 x) public pure {
        uint256 root = ChronosMath.sqrt(uint256(x));
        assertLe(root * root, uint256(x));
        if (root < type(uint128).max) {
            assertGt((root + 1) * (root + 1), uint256(x));
        }
    }

    function test_MulDivWad() public pure {
        uint256 a = 2 * WAD;
        uint256 b = 3 * WAD;
        assertEq(ChronosMath.mulWad(a, b), 6 * WAD);
        assertEq(ChronosMath.divWad(6 * WAD, 2 * WAD), 3 * WAD);
    }

    function testFuzz_MulDivWad(uint64 x, uint64 y) public pure {
        vm.assume(y > 0);
        uint256 wadX = uint256(x) * WAD;
        uint256 wadY = uint256(y) * WAD;
        uint256 mul = ChronosMath.mulWad(wadX, wadY);
        uint256 div = ChronosMath.divWad(mul, wadY);
        // Due to rounding, div should equal wadX within 1 unit
        assertApproxEqAbs(div, wadX, 1);
    }

    function test_Quote() public pure {
        uint256 amountA = 100 * WAD;
        uint256 reserveA = 1000 * WAD;
        uint256 reserveB = 2000 * WAD;
        assertEq(ChronosMath.quote(amountA, reserveA, reserveB), 200 * WAD);
    }

    function test_GetAmountOutAndIn() public pure {
        uint256 reserveIn = 1000 * WAD;
        uint256 reserveOut = 1000 * WAD;
        uint256 amountIn = 10 * WAD;
        uint256 feeBps = 30; // 0.30%

        uint256 amountOut = ChronosMath.getAmountOut(amountIn, reserveIn, reserveOut, feeBps);
        assertGt(amountOut, 0);
        assertLt(amountOut, amountIn); // Slippage & fee ensure output is less than 1:1

        uint256 requiredIn = ChronosMath.getAmountIn(amountOut, reserveIn, reserveOut, feeBps);
        assertApproxEqAbs(requiredIn, amountIn, 2);
    }

    function test_ComputeVirtualSwap_Unilateral() public pure {
        uint256 xReserve = 1000 * WAD;
        uint256 yReserve = 1000 * WAD;
        uint256 xIn = 10 * WAD;
        uint256 yIn = 0;
        uint256 feeBps = 30;

        (uint256 xOut, uint256 yOut, uint256 newX, uint256 newY) =
            ChronosMath.computeVirtualSwap(xIn, yIn, xReserve, yReserve, feeBps);

        assertEq(xOut, 0);
        assertGt(yOut, 0);
        assertEq(newX, xReserve + xIn);
        assertEq(newY, yReserve - yOut);
    }

    function test_ComputeVirtualSwap_BilateralEqual() public pure {
        uint256 xReserve = 1000 * WAD;
        uint256 yReserve = 1000 * WAD;
        uint256 xIn = 10 * WAD;
        uint256 yIn = 10 * WAD;
        uint256 feeBps = 30;

        (uint256 xOut, uint256 yOut, uint256 newX, uint256 newY) =
            ChronosMath.computeVirtualSwap(xIn, yIn, xReserve, yReserve, feeBps);

        assertGt(xOut, 0);
        assertGt(yOut, 0);
        assertEq(xOut, yOut); // Exact symmetric match
        assertEq(newX, xReserve + xIn - xOut);
        assertEq(newY, yReserve + yIn - yOut);
    }
}
