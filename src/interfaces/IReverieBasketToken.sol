// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "./IERC20.sol";

interface IReverieBasketToken is IERC20 {
    function vault() external view returns (address);
    function mint(address receiver, uint256 amount) external;
    function burn(address account, uint256 amount) external;
}
