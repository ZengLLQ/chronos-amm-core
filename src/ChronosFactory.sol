// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IChronosFactory} from "./interfaces/IChronosFactory.sol";
import {ChronosPair} from "./ChronosPair.sol";

/// @title ChronosFactory
/// @notice Deploys and catalogs Chronos AMM Pairs via deterministic CREATE2
contract ChronosFactory is IChronosFactory {
    error IdenticalAddresses();
    error ZeroAddress();
    error PairExists();
    error Forbidden();

    address public feeTo;
    address public feeToSetter;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    constructor(address _feeToSetter) {
        if (_feeToSetter == address(0)) revert ZeroAddress();
        feeToSetter = _feeToSetter;
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        if (tokenA == tokenB) revert IdenticalAddresses();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();
        if (getPair[token0][token1] != address(0)) revert PairExists();

        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        ChronosPair newPair = new ChronosPair{salt: salt}();

        pair = address(newPair);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);

        emit PairCreated(token0, token1, pair, allPairs.length);

        newPair.initialize(token0, token1);
    }

    function setFeeTo(address _feeTo) external {
        if (msg.sender != feeToSetter) revert Forbidden();
        emit FeeToUpdated(feeTo, _feeTo);
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        if (msg.sender != feeToSetter) revert Forbidden();
        if (_feeToSetter == address(0)) revert ZeroAddress();
        emit FeeToSetterUpdated(feeToSetter, _feeToSetter);
        feeToSetter = _feeToSetter;
    }
}
