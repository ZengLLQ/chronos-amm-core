// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IChronosCallee
/// @notice Interface for receiver of ChronosPair flash swaps
interface IChronosCallee {
    function chronosCall(address sender, uint256 amount0Out, uint256 amount1Out, bytes calldata data) external;
}
