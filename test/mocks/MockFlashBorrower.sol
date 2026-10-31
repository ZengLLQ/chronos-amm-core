// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC3156FlashBorrower} from "../../src/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IChronosPair} from "../../src/interfaces/IChronosPair.sol";

contract MockFlashBorrower is IERC3156FlashBorrower {
    bytes32 private constant FLASH_LOAN_RETURN = keccak256("ERC3156FlashBorrower.onFlashLoan");

    enum Action {
        NORMAL,
        FAIL_RETURN,
        NO_REPAY,
        REENTER
    }

    Action public action = Action.NORMAL;

    function setAction(Action _action) external {
        action = _action;
    }

    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata)
        external
        override
        returns (bytes32)
    {
        if (action == Action.FAIL_RETURN) {
            return bytes32(0);
        }

        if (action == Action.REENTER) {
            // Attempt to re-enter the pool
            IChronosPair(msg.sender).swap(0, 0, address(this), new bytes(0));
        }

        if (action == Action.NO_REPAY) {
            // Do not approve or transfer tokens back
            return FLASH_LOAN_RETURN;
        }

        // Action.NORMAL: approve repayment of amount + fee
        IERC20(token).approve(msg.sender, amount + fee);
        return FLASH_LOAN_RETURN;
    }
}
