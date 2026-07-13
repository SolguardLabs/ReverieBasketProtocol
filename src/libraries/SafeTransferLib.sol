// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {ReverieErrors} from "../errors/ReverieErrors.sol";

library SafeTransferLib {
    function safeTransfer(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool success, bytes memory data) = token.call(
            abi.encodeCall(IERC20.transfer, (to, amount))
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert ReverieErrors.TransferFailed();
        }
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool success, bytes memory data) = token.call(
            abi.encodeCall(IERC20.transferFrom, (from, to, amount))
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert ReverieErrors.TransferFailed();
        }
    }

    function safeApprove(address token, address spender, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeCall(IERC20.approve, (spender, amount))
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert ReverieErrors.TransferFailed();
        }
    }

    function balanceOf(address token, address account) internal view returns (uint256 balance) {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeCall(IERC20.balanceOf, (account))
        );
        if (!success || data.length < 32) revert ReverieErrors.TransferFailed();
        balance = abi.decode(data, (uint256));
    }
}
