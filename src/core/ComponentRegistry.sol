// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReverieRoles} from "../access/ReverieRoles.sol";
import {BasketMath} from "../libraries/BasketMath.sol";
import {ComponentConfig, ComponentStatus} from "../types/ReverieTypes.sol";
import {ReverieErrors} from "../errors/ReverieErrors.sol";

contract ComponentRegistry is ReverieRoles {
    mapping(address asset => ComponentConfig config) private _components;
    address[] private _allAssets;

    event ComponentListed(
        address indexed asset,
        uint8 decimals,
        uint16 weightBps,
        uint16 maxDriftBps,
        uint16 harvestFeeBps
    );
    event ComponentStatusUpdated(
        address indexed asset,
        ComponentStatus oldStatus,
        ComponentStatus newStatus
    );
    event ComponentWeightUpdated(address indexed asset, uint16 oldWeightBps, uint16 newWeightBps);
    event ComponentTargetUpdated(address indexed asset, uint16 oldTargetBps, uint16 newTargetBps);
    event ComponentRiskUpdated(
        address indexed asset,
        uint16 maxDriftBps,
        uint16 harvestFeeBps,
        uint96 maxBalance
    );
    event ComponentRedeemableUpdated(address indexed asset, bool redeemable);
    event ComponentYieldUpdated(address indexed asset, bool yieldEnabled);

    constructor(address admin) ReverieRoles(admin) {}

    function listComponent(
        address asset,
        uint8 decimals_,
        uint16 weightBps,
        uint16 maxDriftBps,
        uint16 harvestFeeBps,
        uint96 maxBalance,
        bool yieldEnabled
    ) external onlyRole(GOVERNOR_ROLE) {
        if (asset == address(0)) revert ReverieErrors.ZeroAddress();
        if (_components[asset].status != ComponentStatus.Unlisted) {
            revert ReverieErrors.ComponentAlreadyListed(asset);
        }
        if (decimals_ > 30) revert ReverieErrors.InvalidComponent(asset);
        if (weightBps > BasketMath.BPS) revert ReverieErrors.InvalidWeight(asset, weightBps);

        ComponentStatus status = weightBps == 0
            ? ComponentStatus.PendingAdd
            : ComponentStatus.Active;
        _components[asset] = ComponentConfig({
            asset: asset,
            decimals: decimals_,
            weightBps: weightBps,
            targetWeightBps: weightBps,
            maxDriftBps: maxDriftBps,
            harvestFeeBps: harvestFeeBps,
            maxBalance: maxBalance,
            status: status,
            redeemable: status == ComponentStatus.Active,
            yieldEnabled: yieldEnabled,
            listedAt: uint40(block.timestamp),
            updatedAt: uint40(block.timestamp)
        });
        _allAssets.push(asset);
        emit ComponentListed(asset, decimals_, weightBps, maxDriftBps, harvestFeeBps);
    }

    function setComponentRisk(
        address asset,
        uint16 maxDriftBps,
        uint16 harvestFeeBps,
        uint96 maxBalance
    ) external onlyRole(RISK_MANAGER_ROLE) {
        ComponentConfig storage component = _requireListed(asset);
        component.maxDriftBps = maxDriftBps;
        component.harvestFeeBps = harvestFeeBps;
        component.maxBalance = maxBalance;
        component.updatedAt = uint40(block.timestamp);
        emit ComponentRiskUpdated(asset, maxDriftBps, harvestFeeBps, maxBalance);
    }

    function setRedeemable(address asset, bool redeemable) external onlyRole(RISK_MANAGER_ROLE) {
        ComponentConfig storage component = _requireListed(asset);
        component.redeemable = redeemable;
        component.updatedAt = uint40(block.timestamp);
        emit ComponentRedeemableUpdated(asset, redeemable);
    }

    function setYieldEnabled(address asset, bool enabled) external onlyRole(RISK_MANAGER_ROLE) {
        ComponentConfig storage component = _requireListed(asset);
        component.yieldEnabled = enabled;
        component.updatedAt = uint40(block.timestamp);
        emit ComponentYieldUpdated(asset, enabled);
    }

    function setTargetWeights(
        address[] calldata assets,
        uint16[] calldata targetWeights
    ) external onlyRole(REBALANCER_ROLE) {
        BasketMath.validateTargetWeights(_copyAssets(assets), _copyWeights(targetWeights));
        for (uint256 i = 0; i < assets.length; ++i) {
            ComponentConfig storage component = _requireListed(assets[i]);
            uint16 oldTarget = component.targetWeightBps;
            component.targetWeightBps = targetWeights[i];
            component.updatedAt = uint40(block.timestamp);
            emit ComponentTargetUpdated(assets[i], oldTarget, targetWeights[i]);
        }
    }

    function applyWeights(
        address[] calldata assets,
        uint16[] calldata weights
    ) external onlyRole(REBALANCER_ROLE) {
        BasketMath.validateTargetWeights(_copyAssets(assets), _copyWeights(weights));
        for (uint256 i = 0; i < assets.length; ++i) {
            ComponentConfig storage component = _requireListed(assets[i]);
            ComponentStatus oldStatus = component.status;
            uint16 oldWeight = component.weightBps;
            component.weightBps = weights[i];
            component.targetWeightBps = weights[i];
            component.redeemable = weights[i] != 0;
            component.status = weights[i] == 0 ? ComponentStatus.Retired : ComponentStatus.Active;
            component.updatedAt = uint40(block.timestamp);
            emit ComponentWeightUpdated(assets[i], oldWeight, weights[i]);
            if (oldStatus != component.status) {
                emit ComponentStatusUpdated(assets[i], oldStatus, component.status);
            }
        }
    }

    function markPendingRemoval(address asset) external onlyRole(REBALANCER_ROLE) {
        ComponentConfig storage component = _requireListed(asset);
        if (component.status != ComponentStatus.Active)
            revert ReverieErrors.ComponentNotActive(asset);
        ComponentStatus oldStatus = component.status;
        component.status = ComponentStatus.PendingRemove;
        component.targetWeightBps = 0;
        component.redeemable = true;
        component.updatedAt = uint40(block.timestamp);
        emit ComponentStatusUpdated(asset, oldStatus, component.status);
        emit ComponentTargetUpdated(asset, component.weightBps, 0);
    }

    function markPendingAdd(
        address asset,
        uint16 targetWeightBps
    ) external onlyRole(REBALANCER_ROLE) {
        ComponentConfig storage component = _requireListed(asset);
        if (
            component.status != ComponentStatus.PendingAdd &&
            component.status != ComponentStatus.Retired &&
            component.status != ComponentStatus.Active
        ) {
            revert ReverieErrors.InvalidComponent(asset);
        }
        ComponentStatus oldStatus = component.status;
        component.status = ComponentStatus.PendingAdd;
        component.targetWeightBps = targetWeightBps;
        component.weightBps = 0;
        component.redeemable = false;
        component.updatedAt = uint40(block.timestamp);
        emit ComponentStatusUpdated(asset, oldStatus, component.status);
        emit ComponentTargetUpdated(asset, 0, targetWeightBps);
    }

    function completeSubstitution(
        address outgoing,
        address incoming,
        uint16 incomingWeightBps
    ) external onlyRole(REBALANCER_ROLE) {
        ComponentConfig storage outComponent = _requireListed(outgoing);
        ComponentConfig storage inComponent = _requireListed(incoming);
        ComponentStatus oldOut = outComponent.status;
        ComponentStatus oldIn = inComponent.status;

        outComponent.status = ComponentStatus.Retired;
        outComponent.weightBps = 0;
        outComponent.targetWeightBps = 0;
        outComponent.redeemable = false;
        outComponent.updatedAt = uint40(block.timestamp);

        inComponent.status = ComponentStatus.Active;
        inComponent.weightBps = incomingWeightBps;
        inComponent.targetWeightBps = incomingWeightBps;
        inComponent.redeemable = true;
        inComponent.updatedAt = uint40(block.timestamp);

        emit ComponentStatusUpdated(outgoing, oldOut, outComponent.status);
        emit ComponentWeightUpdated(outgoing, outComponent.weightBps, 0);
        emit ComponentStatusUpdated(incoming, oldIn, inComponent.status);
        emit ComponentWeightUpdated(incoming, 0, incomingWeightBps);
    }

    function cancelPendingSubstitution(
        address outgoing,
        address incoming
    ) external onlyRole(REBALANCER_ROLE) {
        ComponentConfig storage outComponent = _requireListed(outgoing);
        ComponentConfig storage inComponent = _requireListed(incoming);

        if (outComponent.status == ComponentStatus.PendingRemove) {
            ComponentStatus oldOut = outComponent.status;
            outComponent.status = ComponentStatus.Active;
            outComponent.targetWeightBps = outComponent.weightBps;
            outComponent.redeemable = true;
            outComponent.updatedAt = uint40(block.timestamp);
            emit ComponentStatusUpdated(outgoing, oldOut, outComponent.status);
        }

        if (inComponent.status == ComponentStatus.PendingAdd) {
            ComponentStatus oldIn = inComponent.status;
            inComponent.status = inComponent.weightBps == 0
                ? ComponentStatus.Retired
                : ComponentStatus.Active;
            inComponent.targetWeightBps = inComponent.weightBps;
            inComponent.redeemable = inComponent.status == ComponentStatus.Active;
            inComponent.updatedAt = uint40(block.timestamp);
            emit ComponentStatusUpdated(incoming, oldIn, inComponent.status);
        }
    }

    function getComponent(address asset) external view returns (ComponentConfig memory) {
        ComponentConfig memory component = _components[asset];
        if (component.status == ComponentStatus.Unlisted)
            revert ReverieErrors.ComponentNotListed(asset);
        return component;
    }

    function isListed(address asset) external view returns (bool) {
        return _components[asset].status != ComponentStatus.Unlisted;
    }

    function isActive(address asset) external view returns (bool) {
        return _components[asset].status == ComponentStatus.Active;
    }

    function isBackingComponent(address asset) external view returns (bool) {
        ComponentStatus status = _components[asset].status;
        return status == ComponentStatus.Active || status == ComponentStatus.PendingAdd;
    }

    function isInKindRedeemable(address asset) external view returns (bool) {
        ComponentConfig memory component = _components[asset];
        return
            component.redeemable &&
            (component.status == ComponentStatus.Active ||
                component.status == ComponentStatus.PendingRemove);
    }

    function allComponents() external view returns (address[] memory assets) {
        assets = new address[](_allAssets.length);
        for (uint256 i = 0; i < _allAssets.length; ++i) assets[i] = _allAssets[i];
    }

    function activeComponents() external view returns (address[] memory assets) {
        return _componentsByStatus(ComponentStatus.Active);
    }

    function backingComponents() external view returns (address[] memory assets) {
        uint256 count;
        for (uint256 i = 0; i < _allAssets.length; ++i) {
            ComponentStatus status = _components[_allAssets[i]].status;
            if (status == ComponentStatus.Active || status == ComponentStatus.PendingAdd) count++;
        }
        assets = new address[](count);
        uint256 cursor;
        for (uint256 i = 0; i < _allAssets.length; ++i) {
            ComponentStatus status = _components[_allAssets[i]].status;
            if (status == ComponentStatus.Active || status == ComponentStatus.PendingAdd) {
                assets[cursor++] = _allAssets[i];
            }
        }
    }

    function redeemableComponents() external view returns (address[] memory assets) {
        uint256 count;
        for (uint256 i = 0; i < _allAssets.length; ++i) {
            ComponentConfig memory component = _components[_allAssets[i]];
            if (
                component.redeemable &&
                (component.status == ComponentStatus.Active ||
                    component.status == ComponentStatus.PendingRemove)
            ) count++;
        }
        assets = new address[](count);
        uint256 cursor;
        for (uint256 i = 0; i < _allAssets.length; ++i) {
            ComponentConfig memory component = _components[_allAssets[i]];
            if (
                component.redeemable &&
                (component.status == ComponentStatus.Active ||
                    component.status == ComponentStatus.PendingRemove)
            ) {
                assets[cursor++] = _allAssets[i];
            }
        }
    }

    function componentCount() external view returns (uint256) {
        return _allAssets.length;
    }

    function componentAt(uint256 index) external view returns (address) {
        return _allAssets[index];
    }

    function componentHash() external view returns (bytes32) {
        address[] memory assets = new address[](_allAssets.length);
        uint16[] memory weights = new uint16[](_allAssets.length);
        for (uint256 i = 0; i < _allAssets.length; ++i) {
            address asset = _allAssets[i];
            assets[i] = asset;
            weights[i] = _components[asset].weightBps;
        }
        return keccak256(abi.encode(assets, weights));
    }

    function _componentsByStatus(
        ComponentStatus status
    ) internal view returns (address[] memory assets) {
        uint256 count;
        for (uint256 i = 0; i < _allAssets.length; ++i) {
            if (_components[_allAssets[i]].status == status) count++;
        }
        assets = new address[](count);
        uint256 cursor;
        for (uint256 i = 0; i < _allAssets.length; ++i) {
            if (_components[_allAssets[i]].status == status) assets[cursor++] = _allAssets[i];
        }
    }

    function _requireListed(
        address asset
    ) internal view returns (ComponentConfig storage component) {
        component = _components[asset];
        if (component.status == ComponentStatus.Unlisted)
            revert ReverieErrors.ComponentNotListed(asset);
    }

    function _copyAssets(
        address[] calldata assets
    ) internal pure returns (address[] memory copied) {
        copied = new address[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) copied[i] = assets[i];
    }

    function _copyWeights(
        uint16[] calldata weights
    ) internal pure returns (uint16[] memory copied) {
        copied = new uint16[](weights.length);
        for (uint256 i = 0; i < weights.length; ++i) copied[i] = weights[i];
    }
}
