// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReverieRoles} from "../access/ReverieRoles.sol";
import {IReverieOracle} from "../interfaces/IReverieOracle.sol";
import {ReverieErrors} from "../errors/ReverieErrors.sol";

contract ReveriePriceOracle is ReverieRoles, IReverieOracle {
    struct PriceRecord {
        uint256 price;
        uint256 minPrice;
        uint256 maxPrice;
        uint40 updatedAt;
        uint40 heartbeat;
        bool enabled;
    }

    mapping(address asset => PriceRecord record) private _records;
    address[] private _assets;

    event PriceConfigured(
        address indexed asset,
        uint256 minPrice,
        uint256 maxPrice,
        uint40 heartbeat
    );
    event PriceUpdated(address indexed asset, uint256 oldPrice, uint256 newPrice, uint40 updatedAt);
    event PriceDisabled(address indexed asset);

    constructor(address admin) ReverieRoles(admin) {}

    function configureAsset(
        address asset,
        uint256 minPrice,
        uint256 maxPrice,
        uint40 heartbeat
    ) external onlyRole(RISK_MANAGER_ROLE) {
        if (asset == address(0)) revert ReverieErrors.ZeroAddress();
        if (minPrice == 0 || maxPrice < minPrice)
            revert ReverieErrors.PriceOutOfBounds(asset, minPrice);
        if (heartbeat == 0) revert ReverieErrors.InvalidHeartbeat(heartbeat);

        PriceRecord storage record = _records[asset];
        if (!record.enabled) _assets.push(asset);
        record.minPrice = minPrice;
        record.maxPrice = maxPrice;
        record.heartbeat = heartbeat;
        record.enabled = true;
        emit PriceConfigured(asset, minPrice, maxPrice, heartbeat);
    }

    function setPrice(address asset, uint256 price) external onlyRole(KEEPER_ROLE) {
        PriceRecord storage record = _records[asset];
        if (!record.enabled) revert ReverieErrors.InvalidComponent(asset);
        if (price < record.minPrice || price > record.maxPrice) {
            revert ReverieErrors.PriceOutOfBounds(asset, price);
        }
        uint256 oldPrice = record.price;
        record.price = price;
        record.updatedAt = uint40(block.timestamp);
        emit PriceUpdated(asset, oldPrice, price, uint40(block.timestamp));
    }

    function disableAsset(address asset) external onlyRole(RISK_MANAGER_ROLE) {
        PriceRecord storage record = _records[asset];
        if (!record.enabled) revert ReverieErrors.InvalidComponent(asset);
        record.enabled = false;
        emit PriceDisabled(asset);
    }

    function getPrice(address asset) public view override returns (uint256) {
        PriceRecord memory record = _records[asset];
        if (!record.enabled || record.price == 0) revert ReverieErrors.InvalidComponent(asset);
        if (block.timestamp > uint256(record.updatedAt) + record.heartbeat) {
            revert ReverieErrors.StalePrice(asset, record.updatedAt, record.heartbeat);
        }
        return record.price;
    }

    function priceIsFresh(address asset) external view override returns (bool) {
        PriceRecord memory record = _records[asset];
        if (!record.enabled || record.price == 0) return false;
        return block.timestamp <= uint256(record.updatedAt) + record.heartbeat;
    }

    function priceTimestamp(address asset) external view override returns (uint40) {
        return _records[asset].updatedAt;
    }

    function priceBounds(address asset) external view returns (uint256 minPrice, uint256 maxPrice) {
        PriceRecord memory record = _records[asset];
        return (record.minPrice, record.maxPrice);
    }

    function heartbeat(address asset) external view returns (uint40) {
        return _records[asset].heartbeat;
    }

    function recordOf(address asset) external view returns (PriceRecord memory) {
        return _records[asset];
    }

    function assetCount() external view returns (uint256) {
        return _assets.length;
    }

    function assetAt(uint256 index) external view returns (address) {
        return _assets[index];
    }
}
