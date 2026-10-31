// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IChronosFactory} from "./interfaces/IChronosFactory.sol";
import {IChronosPair} from "./interfaces/IChronosPair.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {ChronosMath} from "./libraries/ChronosMath.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";

/// @title ChronosRouter
/// @notice Periphery router for liquidity provisioning, multihop swaps, and long-term TWAMM order management
contract ChronosRouter {
    using SafeTransferLib for address;

    error Expired();
    error ZeroAddress();
    error InsufficientBAmount();
    error InsufficientAAmount();
    error InsufficientOutputAmount();
    error ExcessiveInputAmount();
    error InvalidPath();
    error PairNotFound();

    address public immutable factory;

    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) revert Expired();
        _;
    }

    constructor(address _factory) {
        if (_factory == address(0)) revert ZeroAddress();
        factory = _factory;
    }

    // =========================================================
    //                    LIQUIDITY MANAGEMENT
    // =========================================================

    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal returns (uint256 amountA, uint256 amountB) {
        address pair = IChronosFactory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) {
            pair = IChronosFactory(factory).createPair(tokenA, tokenB);
        }
        (uint112 reserveA, uint112 reserveB,) = IChronosPair(pair).getReserves();
        if (tokenA > tokenB) {
            (reserveA, reserveB) = (reserveB, reserveA);
        }

        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = ChronosMath.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                if (amountBOptimal < amountBMin) revert InsufficientBAmount();
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = ChronosMath.quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                if (amountAOptimal < amountAMin) revert InsufficientAAmount();
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = IChronosFactory(factory).getPair(tokenA, tokenB);
        tokenA.safeTransferFrom(msg.sender, pair, amountA);
        tokenB.safeTransferFrom(msg.sender, pair, amountB);
        liquidity = IChronosPair(pair).mint(to);
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) public ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        address pair = IChronosFactory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) revert PairNotFound();

        pair.safeTransferFrom(msg.sender, pair, liquidity);
        (uint256 amount0, uint256 amount1) = IChronosPair(pair).burn(to);
        (address token0,) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        if (amountA < amountAMin) revert InsufficientAAmount();
        if (amountB < amountBMin) revert InsufficientBAmount();
    }

    // =========================================================
    //                        SWAP LOGIC
    // =========================================================

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        if (path.length < 2) revert InvalidPath();
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;

        for (uint256 i = 0; i < path.length - 1; i++) {
            address pair = IChronosFactory(factory).getPair(path[i], path[i + 1]);
            if (pair == address(0)) revert PairNotFound();

            (uint112 reserve0, uint112 reserve1,) = IChronosPair(pair).getReserves();
            (uint112 reserveIn, uint112 reserveOut) =
                path[i] < path[i + 1] ? (reserve0, reserve1) : (reserve1, reserve0);
            uint256 feeBps = IChronosPair(pair).currentDynamicFeeBps();
            amounts[i + 1] = ChronosMath.getAmountOut(amounts[i], reserveIn, reserveOut, feeBps);
        }

        if (amounts[amounts.length - 1] < amountOutMin) revert InsufficientOutputAmount();

        // Transfer initial input to the first pair
        address firstPair = IChronosFactory(factory).getPair(path[0], path[1]);
        path[0].safeTransferFrom(msg.sender, firstPair, amounts[0]);

        // Execute hops
        for (uint256 i = 0; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = input < output ? (input, output) : (output, input);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) =
                input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
            address recipient = i < path.length - 2 ? IChronosFactory(factory).getPair(output, path[i + 2]) : to;
            address pair = IChronosFactory(factory).getPair(input, output);
            IChronosPair(pair).swap(amount0Out, amount1Out, recipient, new bytes(0));
        }
    }

    // =========================================================
    //                    TWAMM ORDER HELPERS
    // =========================================================

    function submitLongTermOrder(address tokenIn, address tokenOut, uint256 amountIn, uint256 numberOfIntervals)
        external
        returns (uint256 orderId)
    {
        address pair = IChronosFactory(factory).getPair(tokenIn, tokenOut);
        if (pair == address(0)) revert PairNotFound();

        bool isToken0 = tokenIn < tokenOut;
        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        tokenIn.safeApprove(pair, amountIn);

        orderId = IChronosPair(pair).submitLongTermOrder(isToken0, amountIn, numberOfIntervals);
    }
}
