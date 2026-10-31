// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IERC3156FlashBorrower
/// @notice Interface for receiver of ERC-3156 flash loans
interface IERC3156FlashBorrower {
    /// @notice Receive a flash loan.
    /// @param initiator The initiator of the loan.
    /// @param token The loan currency.
    /// @param amount The amount of tokens lent.
    /// @param fee The additional amount of tokens to repay as a fee.
    /// @param data Arbitrary data structured, passed through by the execution.
    /// @return The keccak256 hash of "ERC3156FlashBorrower.onFlashLoan"
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32);
}
