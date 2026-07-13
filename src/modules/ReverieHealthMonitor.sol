// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ComponentRegistry} from "../core/ComponentRegistry.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";
import {ReveriePriceOracle} from "../oracle/ReveriePriceOracle.sol";
import {ReverieRiskPolicy} from "../policy/ReverieRiskPolicy.sol";
import {ReverieBasketProtocol} from "../vault/ReverieBasketProtocol.sol";
import {ComponentConfig, ComponentStatus, NavReport, ScheduleState, SubstitutionPlan} from "../types/ReverieTypes.sol";

contract ReverieHealthMonitor {
    using FixedPointMath for uint256;

    struct ComponentHealth {
        address asset;
        uint256 balance;
        uint256 value;
        uint256 observedWeightBps;
        uint256 targetWeightBps;
        uint256 driftBps;
        bool priceFresh;
        bool capExceeded;
        bool driftExceeded;
        ComponentStatus status;
    }

    struct ProtocolHealth {
        NavReport nav;
        bool paused;
        bool substitutionOpen;
        bool weightUpdateOpen;
        bool accountingDiscounted;
        bool anyPriceStale;
        bool anyCapExceeded;
        bool anyDriftExceeded;
    }

    ReverieBasketProtocol public immutable protocol;
    ComponentRegistry public immutable registry;
    ReveriePriceOracle public immutable oracle;
    ReverieRiskPolicy public immutable policy;

    constructor(
        ReverieBasketProtocol protocol_,
        ComponentRegistry registry_,
        ReveriePriceOracle oracle_,
        ReverieRiskPolicy policy_
    ) {
        protocol = protocol_;
        registry = registry_;
        oracle = oracle_;
        policy = policy_;
    }

    function protocolHealth() external view returns (ProtocolHealth memory health) {
        NavReport memory nav = protocol.navReport();
        ComponentHealth[] memory components = componentHealth();
        bool anyPriceStale;
        bool anyCapExceeded;
        bool anyDriftExceeded;
        for (uint256 i = 0; i < components.length; ++i) {
            if (!components[i].priceFresh) anyPriceStale = true;
            if (components[i].capExceeded) anyCapExceeded = true;
            if (components[i].driftExceeded) anyDriftExceeded = true;
        }
        SubstitutionPlan memory substitution = protocol.currentSubstitution();
        health = ProtocolHealth({
            nav: nav,
            paused: protocol.paused(),
            substitutionOpen: substitution.state == ScheduleState.Announced ||
                substitution.state == ScheduleState.Funded,
            weightUpdateOpen: protocol.currentWeightUpdate().state == ScheduleState.Announced,
            accountingDiscounted: nav.accountingValue < nav.grossValue,
            anyPriceStale: anyPriceStale,
            anyCapExceeded: anyCapExceeded,
            anyDriftExceeded: anyDriftExceeded
        });
    }

    function componentHealth() public view returns (ComponentHealth[] memory health) {
        address[] memory assets = registry.allComponents();
        uint256 grossValue = protocol.grossBasketValue();
        health = new ComponentHealth[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            health[i] = _componentHealth(assets[i], grossValue);
        }
    }

    function backingHealth() external view returns (ComponentHealth[] memory health) {
        address[] memory assets = registry.backingComponents();
        uint256 accountingValue = protocol.accountingBasketValue();
        health = new ComponentHealth[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            health[i] = _componentHealth(assets[i], accountingValue);
        }
    }

    function staleAssets() external view returns (address[] memory assets) {
        address[] memory all = registry.allComponents();
        uint256 count;
        for (uint256 i = 0; i < all.length; ++i) {
            if (!oracle.priceIsFresh(all[i])) count++;
        }
        assets = new address[](count);
        uint256 cursor;
        for (uint256 i = 0; i < all.length; ++i) {
            if (!oracle.priceIsFresh(all[i])) assets[cursor++] = all[i];
        }
    }

    function assetsAboveCap() external view returns (address[] memory assets) {
        address[] memory all = registry.allComponents();
        uint256 count;
        for (uint256 i = 0; i < all.length; ++i) {
            ComponentConfig memory component = registry.getComponent(all[i]);
            if (
                component.maxBalance != 0 &&
                IERC20(all[i]).balanceOf(address(protocol)) > component.maxBalance
            ) {
                count++;
            }
        }
        assets = new address[](count);
        uint256 cursor;
        for (uint256 i = 0; i < all.length; ++i) {
            ComponentConfig memory component = registry.getComponent(all[i]);
            if (
                component.maxBalance != 0 &&
                IERC20(all[i]).balanceOf(address(protocol)) > component.maxBalance
            ) {
                assets[cursor++] = all[i];
            }
        }
    }

    function substitutionReadiness()
        external
        view
        returns (
            bool open,
            bool executable,
            uint256 incomingValue,
            uint256 minimumValue,
            uint256 shortfall
        )
    {
        SubstitutionPlan memory plan = protocol.currentSubstitution();
        open = plan.state == ScheduleState.Announced || plan.state == ScheduleState.Funded;
        if (!open) return (false, false, 0, 0, 0);
        executable = block.timestamp >= plan.executableAt && block.timestamp <= plan.expiresAt;

        ComponentConfig memory incoming = registry.getComponent(plan.incoming);
        incomingValue = FixedPointMath.valueOf(
            IERC20(plan.incoming).balanceOf(address(protocol)),
            incoming.decimals,
            oracle.getPrice(plan.incoming)
        );
        minimumValue =
            plan.incomingRequiredValue -
            plan.incomingRequiredValue.bps(policy.maxSubstitutionShortfallBps());
        shortfall = incomingValue >= minimumValue ? 0 : minimumValue - incomingValue;
    }

    function _componentHealth(
        address asset,
        uint256 totalValue
    ) internal view returns (ComponentHealth memory out) {
        ComponentConfig memory component = registry.getComponent(asset);
        uint256 balance = IERC20(asset).balanceOf(address(protocol));
        uint256 price = oracle.getPrice(asset);
        uint256 value = FixedPointMath.valueOf(balance, component.decimals, price);
        uint256 observed = totalValue == 0 ? 0 : FixedPointMath.mulDiv(value, 10_000, totalValue);
        uint256 target = component.targetWeightBps;
        uint256 drift = observed > target ? observed - target : target - observed;
        out = ComponentHealth({
            asset: asset,
            balance: balance,
            value: value,
            observedWeightBps: observed,
            targetWeightBps: target,
            driftBps: drift,
            priceFresh: oracle.priceIsFresh(asset),
            capExceeded: component.maxBalance != 0 && balance > component.maxBalance,
            driftExceeded: drift > component.maxDriftBps,
            status: component.status
        });
    }
}
