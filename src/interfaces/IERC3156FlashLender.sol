// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC3156FlashBorrower} from "./IERC3156FlashBorrower.sol";

/// @title IERC3156FlashLender
/// @notice Interface for lender of ERC-3156 flash loans
interface IERC3156FlashLender {
    /// @notice Maximum amount of currency available for loan.
    function maxFlashLoan(address token) external view returns (uint256);

    /// @notice The fee applied to loaned volume for a loan.
    function flashFee(address token, uint256 amount) external view returns (uint256);

    /// @notice Initiate a flash loan.
    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        returns (bool);
}
