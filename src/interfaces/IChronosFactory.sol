// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IChronosFactory
/// @notice Interface for Chronos AMM Factory
interface IChronosFactory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 allPairsLength);
    event FeeToUpdated(address indexed prevFeeTo, address indexed newFeeTo);
    event FeeToSetterUpdated(address indexed prevSetter, address indexed newSetter);

    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint256 index) external view returns (address pair);
    function allPairsLength() external view returns (uint256);
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function setFeeTo(address) external;
    function setFeeToSetter(address) external;
}
