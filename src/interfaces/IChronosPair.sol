// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC3156FlashLender} from "./IERC3156FlashLender.sol";

/// @title IChronosPair
/// @notice Core interface for Chronos AMM Pair combining Constant Product AMM, TWAMM, and Dynamic Volatility Fees
interface IChronosPair is IERC3156FlashLender {
    struct Order {
        address owner;
        uint256 saleRate; // tokens sold per interval
        uint256 startInterval; // interval when order starts execution
        uint256 endInterval; // interval when order ends execution
        uint256 lastClaimedInterval; // last claimed interval checkpoint
        bool isToken0; // true if selling token0 for token1
    }

    struct OrderPoolView {
        uint256 currentSalesRate;
        uint256 currentRewardFactor;
    }

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to,
        uint256 effectiveFeeBps
    );
    event Sync(uint112 reserve0, uint112 reserve1);
    event TwammExecuted(
        uint256 indexed fromInterval,
        uint256 indexed toInterval,
        uint256 virtualIn0,
        uint256 virtualOut1,
        uint256 virtualIn1,
        uint256 virtualOut0
    );
    event LongTermOrderSubmitted(
        uint256 indexed orderId,
        address indexed owner,
        bool isToken0,
        uint256 amountIn,
        uint256 startInterval,
        uint256 endInterval
    );
    event LongTermOrderCancelled(
        uint256 indexed orderId, address indexed owner, uint256 unsoldRefund, uint256 purchasedClaim
    );
    event LongTermOrderClaimed(uint256 indexed orderId, address indexed owner, uint256 purchasedClaim);

    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function kLast() external view returns (uint256);

    function mint(address to) external returns (uint256 liquidity);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;

    // TWAMM & Dynamic Fee
    function intervalLength() external view returns (uint256);
    function currentInterval() external view returns (uint256);
    function lastVirtualExecutionInterval() external view returns (uint256);
    function currentDynamicFeeBps() external view returns (uint256);
    function executeTwamm() external;
    function submitLongTermOrder(bool isToken0, uint256 amountIn, uint256 numberOfIntervals)
        external
        returns (uint256 orderId);
    function cancelLongTermOrder(uint256 orderId) external returns (uint256 unsoldRefund, uint256 purchasedClaim);
    function claimLongTermOrder(uint256 orderId) external returns (uint256 purchasedClaim);
    function getOrder(uint256 orderId) external view returns (Order memory);
    function getOrderPool(bool isToken0) external view returns (uint256 currentSalesRate, uint256 currentRewardFactor);
}
