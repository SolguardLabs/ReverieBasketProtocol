// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReverieRoles} from "../access/ReverieRoles.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {ReverieErrors} from "../errors/ReverieErrors.sol";

contract ReverieBufferedYieldAdapter is ReverieRoles {
    using SafeTransferLib for address;
    using FixedPointMath for uint256;

    struct StrategyPosition {
        uint256 principal;
        uint256 realizedYield;
        uint256 loss;
        uint256 reservedLiquidity;
        uint40 lastReportAt;
        bool enabled;
    }

    address public immutable vault;
    mapping(address asset => StrategyPosition position) private _positions;
    address[] private _assets;
    mapping(address asset => bool seen) private _seenAsset;

    event StrategyAssetEnabled(address indexed asset);
    event StrategyAssetDisabled(address indexed asset);
    event Deposited(address indexed asset, uint256 amount);
    event Withdrawn(address indexed asset, address indexed receiver, uint256 amount);
    event YieldReported(address indexed asset, uint256 amount, bytes32 indexed reportHash);
    event LossReported(address indexed asset, uint256 amount, bytes32 indexed reportHash);
    event LiquidityReserved(address indexed asset, uint256 amount);
    event LiquidityReleased(address indexed asset, uint256 amount);

    constructor(address admin, address vault_) ReverieRoles(admin) {
        if (vault_ == address(0)) revert ReverieErrors.ZeroAddress();
        vault = vault_;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert ReverieErrors.Unauthorized(msg.sender, keccak256("VAULT"));
        _;
    }

    function enableAsset(address asset) external onlyRole(STRATEGIST_ROLE) {
        if (asset == address(0)) revert ReverieErrors.ZeroAddress();
        StrategyPosition storage position = _positions[asset];
        position.enabled = true;
        _track(asset);
        emit StrategyAssetEnabled(asset);
    }

    function disableAsset(address asset) external onlyRole(STRATEGIST_ROLE) {
        StrategyPosition storage position = _positions[asset];
        position.enabled = false;
        emit StrategyAssetDisabled(asset);
    }

    function deposit(address asset, uint256 amount) external onlyVault {
        if (amount == 0) revert ReverieErrors.InvalidAmount();
        StrategyPosition storage position = _positions[asset];
        if (!position.enabled) revert ReverieErrors.InvalidComponent(asset);
        asset.safeTransferFrom(vault, address(this), amount);
        position.principal += amount;
        emit Deposited(asset, amount);
    }

    function withdraw(address asset, uint256 amount, address receiver) external onlyVault {
        if (receiver == address(0)) revert ReverieErrors.ZeroAddress();
        StrategyPosition storage position = _positions[asset];
        uint256 liquid = IERC20(asset).balanceOf(address(this)) - position.reservedLiquidity;
        if (amount > liquid) revert ReverieErrors.InsufficientBalance(asset, liquid, amount);
        if (amount > position.principal) {
            position.realizedYield -= FixedPointMath.min(
                position.realizedYield,
                amount - position.principal
            );
            position.principal = 0;
        } else {
            position.principal -= amount;
        }
        asset.safeTransfer(receiver, amount);
        emit Withdrawn(asset, receiver, amount);
    }

    function reportYield(
        address asset,
        uint256 amount,
        bytes32 reportHash
    ) external onlyRole(KEEPER_ROLE) {
        if (amount == 0) revert ReverieErrors.InvalidAmount();
        StrategyPosition storage position = _positions[asset];
        if (!position.enabled) revert ReverieErrors.InvalidComponent(asset);
        position.realizedYield += amount;
        position.lastReportAt = uint40(block.timestamp);
        emit YieldReported(asset, amount, reportHash);
    }

    function reportLoss(
        address asset,
        uint256 amount,
        bytes32 reportHash
    ) external onlyRole(KEEPER_ROLE) {
        if (amount == 0) revert ReverieErrors.InvalidAmount();
        StrategyPosition storage position = _positions[asset];
        if (!position.enabled) revert ReverieErrors.InvalidComponent(asset);
        uint256 principalWriteDown = FixedPointMath.min(position.principal, amount);
        position.principal -= principalWriteDown;
        position.loss += amount;
        position.lastReportAt = uint40(block.timestamp);
        emit LossReported(asset, amount, reportHash);
    }

    function reserveLiquidity(address asset, uint256 amount) external onlyRole(KEEPER_ROLE) {
        StrategyPosition storage position = _positions[asset];
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (amount > balance) revert ReverieErrors.InsufficientBalance(asset, balance, amount);
        position.reservedLiquidity += amount;
        emit LiquidityReserved(asset, amount);
    }

    function releaseLiquidity(address asset, uint256 amount) external onlyRole(KEEPER_ROLE) {
        StrategyPosition storage position = _positions[asset];
        if (amount > position.reservedLiquidity) {
            revert ReverieErrors.InsufficientBalance(asset, position.reservedLiquidity, amount);
        }
        position.reservedLiquidity -= amount;
        emit LiquidityReleased(asset, amount);
    }

    function totalAssets(address asset) external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function liquidAssets(address asset) external view returns (uint256) {
        StrategyPosition memory position = _positions[asset];
        uint256 balance = IERC20(asset).balanceOf(address(this));
        return balance > position.reservedLiquidity ? balance - position.reservedLiquidity : 0;
    }

    function positionOf(address asset) external view returns (StrategyPosition memory) {
        return _positions[asset];
    }

    function managedAssets() external view returns (address[] memory assets) {
        assets = new address[](_assets.length);
        for (uint256 i = 0; i < _assets.length; ++i) assets[i] = _assets[i];
    }

    function _track(address asset) internal {
        if (!_seenAsset[asset]) {
            _seenAsset[asset] = true;
            _assets.push(asset);
        }
    }
}
