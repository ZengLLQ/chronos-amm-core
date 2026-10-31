// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChronosFactory} from "../src/ChronosFactory.sol";
import {ChronosRouter} from "../src/ChronosRouter.sol";
import {ChronosPair} from "../src/ChronosPair.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ChronosRouterTest is Test {
    uint256 internal constant WAD = 1e18;

    ChronosFactory internal factory;
    ChronosRouter internal router;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal tokenC;

    address internal feeSetter = address(0xFEE);
    address internal user = address(0xCAFE);

    function setUp() public {
        vm.label(user, "User");

        factory = new ChronosFactory(feeSetter);
        router = new ChronosRouter(address(factory));

        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        tokenC = new MockERC20("Token C", "TKNC", 18);

        tokenA.mint(user, 1_000_000 * WAD);
        tokenB.mint(user, 1_000_000 * WAD);
        tokenC.mint(user, 1_000_000 * WAD);

        vm.startPrank(user);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function test_AddAndRemoveLiquidity() public {
        vm.startPrank(user);
        uint256 amountA = 1000 * WAD;
        uint256 amountB = 2000 * WAD;

        (uint256 actualA, uint256 actualB, uint256 liquidity) = router.addLiquidity(
            address(tokenA), address(tokenB), amountA, amountB, amountA, amountB, user, block.timestamp + 100
        );

        assertEq(actualA, amountA);
        assertEq(actualB, amountB);
        assertGt(liquidity, 0);

        address pair = factory.getPair(address(tokenA), address(tokenB));
        ChronosPair(pair).approve(address(router), liquidity);

        (uint256 remA, uint256 remB) = router.removeLiquidity(
            address(tokenA),
            address(tokenB),
            liquidity,
            amountA * 99 / 100,
            amountB * 99 / 100,
            user,
            block.timestamp + 100
        );

        assertGt(remA, 0);
        assertGt(remB, 0);
        vm.stopPrank();
    }

    function test_MultiHopSwap() public {
        vm.startPrank(user);
        // Pair A-B: 10,000 A : 10,000 B
        router.addLiquidity(
            address(tokenA), address(tokenB), 10_000 * WAD, 10_000 * WAD, 0, 0, user, block.timestamp + 100
        );

        // Pair B-C: 10,000 B : 20,000 C (1 B = 2 C)
        router.addLiquidity(
            address(tokenB), address(tokenC), 10_000 * WAD, 20_000 * WAD, 0, 0, user, block.timestamp + 100
        );

        // Multi-hop swap: 100 A -> B -> C
        address[] memory path = new address[](3);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        path[2] = address(tokenC);

        uint256 balCBefore = tokenC.balanceOf(user);
        uint256[] memory amounts = router.swapExactTokensForTokens(
            100 * WAD,
            190 * WAD, // expecting ~195 C
            path,
            user,
            block.timestamp + 100
        );
        uint256 balCAfter = tokenC.balanceOf(user);

        assertEq(balCAfter - balCBefore, amounts[2]);
        assertGt(amounts[2], 190 * WAD);
        vm.stopPrank();
    }
}
