// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChronosFactory} from "../src/ChronosFactory.sol";
import {ChronosPair} from "../src/ChronosPair.sol";
import {IChronosPair} from "../src/interfaces/IChronosPair.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFlashBorrower} from "./mocks/MockFlashBorrower.sol";

contract ChronosPairTest is Test {
    uint256 internal constant WAD = 1e18;

    ChronosFactory internal factory;
    ChronosPair internal pair;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal token0;
    MockERC20 internal token1;

    address internal feeSetter = address(0xFEEDBEEF);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        vm.label(feeSetter, "FeeSetter");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");

        factory = new ChronosFactory(feeSetter);
        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);

        address pairAddress = factory.createPair(address(tokenA), address(tokenB));
        pair = ChronosPair(pairAddress);

        address p0 = pair.token0();
        address p1 = pair.token1();
        token0 = MockERC20(p0);
        token1 = MockERC20(p1);

        // Mint initial tokens to alice and bob
        token0.mint(alice, 1_000_000 * WAD);
        token1.mint(alice, 1_000_000 * WAD);
        token0.mint(bob, 1_000_000 * WAD);
        token1.mint(bob, 1_000_000 * WAD);
    }

    function test_InitialMintAndMinimumLiquidity() public {
        vm.startPrank(alice);
        uint256 deposit0 = 1000 * WAD;
        uint256 deposit1 = 1000 * WAD;

        token0.transfer(address(pair), deposit0);
        token1.transfer(address(pair), deposit1);

        pair.mint(alice);
        vm.stopPrank();

        // Total liquidity should be sqrt(deposit0 * deposit1) = 1000 * WAD
        // MINIMUM_LIQUIDITY (1000) locked permanently at address(0)
        assertEq(pair.totalSupply(), 1000 * WAD);
        assertEq(pair.balanceOf(alice), 1000 * WAD - pair.MINIMUM_LIQUIDITY());
        assertEq(pair.balanceOf(address(0)), pair.MINIMUM_LIQUIDITY());

        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(r0, deposit0);
        assertEq(r1, deposit1);
    }

    function test_StandardSwap() public {
        // Initial liquidity
        vm.startPrank(alice);
        token0.transfer(address(pair), 10_000 * WAD);
        token1.transfer(address(pair), 10_000 * WAD);
        pair.mint(alice);
        vm.stopPrank();

        // Bob swaps 100 token0 for token1
        vm.startPrank(bob);
        uint256 swapIn0 = 100 * WAD;
        token0.transfer(address(pair), swapIn0);

        uint256 expectedOut1 = 98 * WAD; // Approximately 99-98 tokens after slippage and fee
        uint256 bobBal1Before = token1.balanceOf(bob);
        pair.swap(0, expectedOut1, bob, new bytes(0));
        uint256 bobBal1After = token1.balanceOf(bob);

        assertEq(bobBal1After - bobBal1Before, expectedOut1);
        vm.stopPrank();

        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(r0, 10_000 * WAD + swapIn0);
        assertEq(r1, 10_000 * WAD - expectedOut1);
    }

    function test_TwammOrder_SubmitAndExecute() public {
        // Provide liquidity
        vm.startPrank(alice);
        token0.transfer(address(pair), 100_000 * WAD);
        token1.transfer(address(pair), 100_000 * WAD);
        pair.mint(alice);
        vm.stopPrank();

        // Bob submits long-term TWAMM order: sells 1000 token0 over 10 intervals
        vm.startPrank(bob);
        uint256 orderAmount = 1000 * WAD;
        uint256 numIntervals = 10;
        token0.approve(address(pair), orderAmount);
        uint256 orderId = pair.submitLongTermOrder(true, orderAmount, numIntervals);
        assertEq(orderId, 1);
        vm.stopPrank();

        IChronosPair.Order memory order = pair.getOrder(orderId);
        assertEq(order.owner, bob);
        assertEq(order.saleRate, orderAmount / numIntervals);
        assertEq(order.isToken0, true);

        // Warp time by 5 intervals (5 * 10 seconds = 50 seconds)
        vm.warp(block.timestamp + 55);

        // Execute TWAMM
        pair.executeTwamm();

        // Bob claims partial proceeds
        vm.prank(bob);
        uint256 claimed1 = pair.claimLongTermOrder(orderId);
        assertGt(claimed1, 0);
        assertLe(claimed1, orderAmount);

        // Warp past the end of the order (another 60 seconds)
        vm.warp(block.timestamp + 60);
        pair.executeTwamm();

        // Bob claims remaining proceeds
        vm.prank(bob);
        uint256 secondClaim = pair.claimLongTermOrder(orderId);
        assertGt(secondClaim, 0);

        uint256 totalClaimed = claimed1 + secondClaim;
        assertGt(totalClaimed, 900 * WAD); // Received ~990 token1 for 1000 token0
    }

    function test_TwammOrder_Cancellation() public {
        // Liquidity
        vm.startPrank(alice);
        token0.transfer(address(pair), 50_000 * WAD);
        token1.transfer(address(pair), 50_000 * WAD);
        pair.mint(alice);
        vm.stopPrank();

        // Bob submits order: 1000 token0 over 10 intervals
        vm.startPrank(bob);
        uint256 orderAmount = 1000 * WAD;
        token0.approve(address(pair), orderAmount);
        uint256 orderId = pair.submitLongTermOrder(true, orderAmount, 10);

        // Advance 3 intervals
        vm.warp(block.timestamp + 35);
        pair.executeTwamm();

        // Bob cancels order
        uint256 bobToken0Before = token0.balanceOf(bob);
        uint256 bobToken1Before = token1.balanceOf(bob);

        (uint256 unsoldRefund, uint256 purchasedClaim) = pair.cancelLongTermOrder(orderId);

        uint256 bobToken0After = token0.balanceOf(bob);
        uint256 bobToken1After = token1.balanceOf(bob);

        assertGt(unsoldRefund, 0);
        assertGt(purchasedClaim, 0);
        assertEq(bobToken0After - bobToken0Before, unsoldRefund);
        assertEq(bobToken1After - bobToken1Before, purchasedClaim);
        vm.stopPrank();
    }

    function test_FlashLoan_ERC3156_Success() public {
        // Liquidity
        vm.startPrank(alice);
        token0.transfer(address(pair), 10_000 * WAD);
        token1.transfer(address(pair), 10_000 * WAD);
        pair.mint(alice);
        vm.stopPrank();

        MockFlashBorrower borrower = new MockFlashBorrower();
        token0.mint(address(borrower), 100 * WAD); // Fund borrower to pay flash loan fee

        uint256 loanAmount = 1000 * WAD;
        uint256 fee = pair.flashFee(address(token0), loanAmount);
        assertEq(fee, (loanAmount * pair.currentDynamicFeeBps()) / 10000);

        bool success = pair.flashLoan(borrower, address(token0), loanAmount, new bytes(0));
        assertTrue(success);

        (uint112 r0,,) = pair.getReserves();
        assertEq(r0, 10_000 * WAD + fee);
    }

    function test_FlashLoan_RevertOnNoRepay() public {
        // Liquidity
        vm.startPrank(alice);
        token0.transfer(address(pair), 10_000 * WAD);
        token1.transfer(address(pair), 10_000 * WAD);
        pair.mint(alice);
        vm.stopPrank();

        MockFlashBorrower borrower = new MockFlashBorrower();
        borrower.setAction(MockFlashBorrower.Action.NO_REPAY);

        vm.expectRevert();
        pair.flashLoan(borrower, address(token0), 100 * WAD, new bytes(0));
    }

    function test_FlashLoan_RevertOnReentrancy() public {
        // Liquidity
        vm.startPrank(alice);
        token0.transfer(address(pair), 10_000 * WAD);
        token1.transfer(address(pair), 10_000 * WAD);
        pair.mint(alice);
        vm.stopPrank();

        MockFlashBorrower borrower = new MockFlashBorrower();
        borrower.setAction(MockFlashBorrower.Action.REENTER);

        vm.expectRevert();
        pair.flashLoan(borrower, address(token0), 100 * WAD, new bytes(0));
    }
}
