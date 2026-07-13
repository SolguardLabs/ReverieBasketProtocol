// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IReverieOracle {
    function getPrice(address asset) external view returns (uint256);
    function priceIsFresh(address asset) external view returns (bool);
    function priceTimestamp(address asset) external view returns (uint40);
}
