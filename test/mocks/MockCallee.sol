// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IChronosCallee} from "../../src/interfaces/IChronosCallee.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IChronosPair} from "../../src/interfaces/IChronosPair.sol";

contract MockCallee is IChronosCallee {
    bool public shouldReenter;

    function setShouldReenter(bool _shouldReenter) external {
        shouldReenter = _shouldReenter;
    }

    function chronosCall(address, uint256, uint256, bytes calldata data) external override {
        if (shouldReenter) {
            IChronosPair(msg.sender).mint(address(this));
        }

        // Repay required tokens based on data payload
        if (data.length > 0) {
            (address tokenToRepay, uint256 amountToRepay) = abi.decode(data, (address, uint256));
            if (amountToRepay > 0 && tokenToRepay != address(0)) {
                IERC20(tokenToRepay).transfer(msg.sender, amountToRepay);
            }
        }
    }
}
