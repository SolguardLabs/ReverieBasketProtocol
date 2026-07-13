// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ComponentConfig} from "../types/ReverieTypes.sol";

interface IComponentRegistry {
    event ComponentListed(
        address indexed asset,
        uint8 decimals,
        uint16 weightBps,
        uint16 maxDriftBps,
        uint16 harvestFeeBps
    );
    event ComponentStatusUpdated(address indexed asset, uint8 oldStatus, uint8 newStatus);
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

    function listComponent(
        address asset,
        uint8 decimals_,
        uint16 weightBps,
        uint16 maxDriftBps,
        uint16 harvestFeeBps,
        uint96 maxBalance,
        bool yieldEnabled
    ) external;

    function setComponentRisk(
        address asset,
        uint16 maxDriftBps,
        uint16 harvestFeeBps,
        uint96 maxBalance
    ) external;

    function setRedeemable(address asset, bool redeemable) external;
    function setYieldEnabled(address asset, bool enabled) external;
    function setTargetWeights(address[] calldata assets, uint16[] calldata targetWeights) external;
    function applyWeights(address[] calldata assets, uint16[] calldata weights) external;
    function markPendingRemoval(address asset) external;
    function markPendingAdd(address asset, uint16 targetWeightBps) external;
    function completeSubstitution(
        address outgoing,
        address incoming,
        uint16 incomingWeightBps
    ) external;
    function cancelPendingSubstitution(address outgoing, address incoming) external;

    function getComponent(address asset) external view returns (ComponentConfig memory);
    function isListed(address asset) external view returns (bool);
    function isActive(address asset) external view returns (bool);
    function isBackingComponent(address asset) external view returns (bool);
    function isInKindRedeemable(address asset) external view returns (bool);
    function allComponents() external view returns (address[] memory);
    function activeComponents() external view returns (address[] memory);
    function backingComponents() external view returns (address[] memory);
    function redeemableComponents() external view returns (address[] memory);
    function componentCount() external view returns (uint256);
    function componentAt(uint256 index) external view returns (address);
    function componentHash() external view returns (bytes32);
}
