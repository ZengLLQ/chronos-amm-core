// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChronosFactory} from "../src/ChronosFactory.sol";
import {ChronosPair} from "../src/ChronosPair.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract Handler is Test {
    ChronosPair public immutable pair;
    MockERC20 public immutable token0;
    MockERC20 public immutable token1;

    address internal actor = address(0xAAAA);

    constructor(ChronosPair _pair, MockERC20 _token0, MockERC20 _token1) {
        pair = _pair;
        token0 = _token0;
        token1 = _token1;

        token0.mint(actor, 10_000_000 * 1e18);
        token1.mint(actor, 10_000_000 * 1e18);
    }

    function swap0(uint256 amountInRaw) external {
        uint256 amountIn = bound(amountInRaw, 1e16, 500 * 1e18);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 == 0 || r1 == 0) return;

        uint256 amountOut = (amountIn * 9900 * r1) / (uint256(r0) * 10000 + amountIn * 9900);
        if (amountOut >= r1 || amountOut == 0) return;

        vm.startPrank(actor);
        token0.transfer(address(pair), amountIn);
        pair.swap(0, amountOut, actor, new bytes(0));
        vm.stopPrank();
    }

    function swap1(uint256 amountInRaw) external {
        uint256 amountIn = bound(amountInRaw, 1e16, 500 * 1e18);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 == 0 || r1 == 0) return;

        uint256 amountOut = (amountIn * 9900 * r0) / (uint256(r1) * 10000 + amountIn * 9900);
        if (amountOut >= r0 || amountOut == 0) return;

        vm.startPrank(actor);
        token1.transfer(address(pair), amountIn);
        pair.swap(amountOut, 0, actor, new bytes(0));
        vm.stopPrank();
    }

    function warp(uint256 secondsToWarp) external {
        uint256 delta = bound(secondsToWarp, 1, 100);
        vm.warp(block.timestamp + delta);
        pair.executeTwamm();
    }
}

contract ChronosInvariantsTest is Test {
    ChronosFactory internal factory;
    ChronosPair internal pair;
    MockERC20 internal token0;
    MockERC20 internal token1;
    Handler internal handler;

    function setUp() public {
        factory = new ChronosFactory(address(0xFEE));
        MockERC20 tA = new MockERC20("Token A", "TKNA", 18);
        MockERC20 tB = new MockERC20("Token B", "TKNB", 18);

        address pairAddress = factory.createPair(address(tA), address(tB));
        pair = ChronosPair(pairAddress);

        token0 = MockERC20(pair.token0());
        token1 = MockERC20(pair.token1());

        // Initial deposit
        token0.mint(address(this), 100_000 * 1e18);
        token1.mint(address(this), 100_000 * 1e18);
        token0.transfer(address(pair), 50_000 * 1e18);
        token1.transfer(address(pair), 50_000 * 1e18);
        pair.mint(address(this));

        handler = new Handler(pair, token0, token1);
        targetContract(address(handler));
    }

    /// @notice Invariant: Physical balance of token0 must always be >= reserve0 + orderPool0Balance
    function invariant_SolvencyToken0() public view {
        (uint112 r0,,) = pair.getReserves();
        assertGe(token0.balanceOf(address(pair)), uint256(r0) + pair.orderPool0Balance());
    }

    /// @notice Invariant: Physical balance of token1 must always be >= reserve1 + orderPool1Balance
    function invariant_SolvencyToken1() public view {
        (, uint112 r1,) = pair.getReserves();
        assertGe(token1.balanceOf(address(pair)), uint256(r1) + pair.orderPool1Balance());
    }

    /// @notice Invariant: Permanent minimum liquidity at address(0) is intact
    function invariant_MinimumLiquidityLocked() public view {
        assertGe(pair.balanceOf(address(0)), pair.MINIMUM_LIQUIDITY());
    }
}
