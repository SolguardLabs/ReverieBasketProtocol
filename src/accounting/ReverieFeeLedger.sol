// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReverieRoles} from "../access/ReverieRoles.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {ReverieErrors} from "../errors/ReverieErrors.sol";

contract ReverieFeeLedger is ReverieRoles {
    using SafeTransferLib for address;

    struct FeeBucket {
        uint256 accrued;
        uint256 claimed;
        uint256 reserved;
        uint40 lastAccruedAt;
        uint40 lastClaimedAt;
    }

    struct FeeRoute {
        address receiver;
        uint16 shareBps;
        bool enabled;
    }

    uint256 public constant BPS = 10_000;
    address public immutable vault;

    mapping(address asset => FeeBucket bucket) private _buckets;
    mapping(address asset => FeeRoute[] routes) private _routes;
    address[] private _assets;
    mapping(address asset => bool seen) private _seenAsset;

    event FeesAccrued(address indexed asset, uint256 amount, bytes32 indexed reason);
    event FeesReserved(address indexed asset, uint256 amount);
    event FeesReleased(address indexed asset, uint256 amount);
    event FeesClaimed(address indexed asset, address indexed receiver, uint256 amount);
    event RouteSet(
        address indexed asset,
        uint256 indexed index,
        address receiver,
        uint16 shareBps,
        bool enabled
    );
    event RoutesCleared(address indexed asset);

    constructor(address admin, address vault_) ReverieRoles(admin) {
        if (vault_ == address(0)) revert ReverieErrors.ZeroAddress();
        vault = vault_;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert ReverieErrors.Unauthorized(msg.sender, keccak256("VAULT"));
        _;
    }

    function accrue(address asset, uint256 amount, bytes32 reason) external onlyVault {
        if (asset == address(0)) revert ReverieErrors.ZeroAddress();
        if (amount == 0) revert ReverieErrors.InvalidAmount();
        _trackAsset(asset);
        FeeBucket storage bucket = _buckets[asset];
        bucket.accrued += amount;
        bucket.lastAccruedAt = uint40(block.timestamp);
        emit FeesAccrued(asset, amount, reason);
    }

    function reserve(address asset, uint256 amount) external onlyRole(KEEPER_ROLE) {
        FeeBucket storage bucket = _buckets[asset];
        uint256 claimable = bucket.accrued - bucket.claimed - bucket.reserved;
        if (amount > claimable) revert ReverieErrors.InsufficientBalance(asset, claimable, amount);
        bucket.reserved += amount;
        emit FeesReserved(asset, amount);
    }

    function release(address asset, uint256 amount) external onlyRole(KEEPER_ROLE) {
        FeeBucket storage bucket = _buckets[asset];
        if (amount > bucket.reserved)
            revert ReverieErrors.InsufficientBalance(asset, bucket.reserved, amount);
        bucket.reserved -= amount;
        emit FeesReleased(asset, amount);
    }

    function setRoutes(
        address asset,
        address[] calldata receivers,
        uint16[] calldata shares
    ) external onlyRole(GOVERNOR_ROLE) {
        if (asset == address(0)) revert ReverieErrors.ZeroAddress();
        if (receivers.length == 0 || receivers.length != shares.length) {
            revert ReverieErrors.InvalidArrayLength();
        }
        delete _routes[asset];
        uint256 sum;
        for (uint256 i = 0; i < receivers.length; ++i) {
            if (receivers[i] == address(0)) revert ReverieErrors.ZeroAddress();
            if (shares[i] == 0) revert ReverieErrors.InvalidWeight(receivers[i], shares[i]);
            sum += shares[i];
            _routes[asset].push(
                FeeRoute({receiver: receivers[i], shareBps: shares[i], enabled: true})
            );
            emit RouteSet(asset, i, receivers[i], shares[i], true);
        }
        if (sum != BPS) revert ReverieErrors.InvalidWeightSum(sum);
        _trackAsset(asset);
    }

    function clearRoutes(address asset) external onlyRole(GOVERNOR_ROLE) {
        delete _routes[asset];
        emit RoutesCleared(asset);
    }

    function setRouteEnabled(
        address asset,
        uint256 index,
        bool enabled
    ) external onlyRole(GOVERNOR_ROLE) {
        FeeRoute storage route = _routes[asset][index];
        route.enabled = enabled;
        emit RouteSet(asset, index, route.receiver, route.shareBps, enabled);
    }

    function claim(address asset) external returns (uint256 totalClaimed) {
        FeeRoute[] memory routes = _routes[asset];
        if (routes.length == 0) revert ReverieErrors.InvalidComponent(asset);

        FeeBucket storage bucket = _buckets[asset];
        uint256 claimable = bucket.accrued - bucket.claimed - bucket.reserved;
        if (claimable == 0) revert ReverieErrors.InvalidAmount();

        bucket.claimed += claimable;
        bucket.lastClaimedAt = uint40(block.timestamp);
        totalClaimed = claimable;

        uint256 sent;
        for (uint256 i = 0; i < routes.length; ++i) {
            FeeRoute memory route = routes[i];
            if (!route.enabled) continue;
            uint256 amount = i == routes.length - 1
                ? claimable - sent
                : (claimable * route.shareBps) / BPS;
            sent += amount;
            asset.safeTransferFrom(vault, route.receiver, amount);
            emit FeesClaimed(asset, route.receiver, amount);
        }
    }

    function bucketOf(address asset) external view returns (FeeBucket memory) {
        return _buckets[asset];
    }

    function routeCount(address asset) external view returns (uint256) {
        return _routes[asset].length;
    }

    function routeAt(address asset, uint256 index) external view returns (FeeRoute memory) {
        return _routes[asset][index];
    }

    function routesOf(address asset) external view returns (FeeRoute[] memory routes) {
        routes = new FeeRoute[](_routes[asset].length);
        for (uint256 i = 0; i < routes.length; ++i) routes[i] = _routes[asset][i];
    }

    function claimable(address asset) external view returns (uint256) {
        FeeBucket memory bucket = _buckets[asset];
        return bucket.accrued - bucket.claimed - bucket.reserved;
    }

    function trackedAssets() external view returns (address[] memory assets) {
        assets = new address[](_assets.length);
        for (uint256 i = 0; i < _assets.length; ++i) assets[i] = _assets[i];
    }

    function _trackAsset(address asset) internal {
        if (!_seenAsset[asset]) {
            _seenAsset[asset] = true;
            _assets.push(asset);
        }
    }
}
