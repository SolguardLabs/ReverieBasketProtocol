// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ComponentRegistry} from "../core/ComponentRegistry.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";
import {ReveriePriceOracle} from "../oracle/ReveriePriceOracle.sol";
import {ReverieBasketProtocol} from "../vault/ReverieBasketProtocol.sol";
import {ComponentConfig, ComponentStatus} from "../types/ReverieTypes.sol";

contract ReverieRebalancePlanner {
    using FixedPointMath for uint256;

    struct ComponentPlan {
        address asset;
        uint256 balance;
        uint256 price;
        uint256 currentValue;
        uint256 targetValue;
        int256 valueDelta;
        uint16 currentWeightBps;
        uint16 targetWeightBps;
        ComponentStatus status;
    }

    struct TradePair {
        address sellAsset;
        address buyAsset;
        uint256 sellValue;
        uint256 buyValue;
        uint256 sellAmount;
        uint256 buyAmount;
    }

    ReverieBasketProtocol public immutable protocol;
    ComponentRegistry public immutable registry;
    ReveriePriceOracle public immutable oracle;

    constructor(
        ReverieBasketProtocol protocol_,
        ComponentRegistry registry_,
        ReveriePriceOracle oracle_
    ) {
        protocol = protocol_;
        registry = registry_;
        oracle = oracle_;
    }

    function currentPlan() external view returns (ComponentPlan[] memory plans) {
        address[] memory assets = registry.allComponents();
        uint256 grossValue = protocol.grossBasketValue();
        plans = new ComponentPlan[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            plans[i] = _planFor(assets[i], grossValue);
        }
    }

    function activePlan() external view returns (ComponentPlan[] memory plans) {
        address[] memory assets = registry.activeComponents();
        uint256 grossValue = protocol.grossBasketValue();
        plans = new ComponentPlan[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            plans[i] = _planFor(assets[i], grossValue);
        }
    }

    function substitutionPlan()
        external
        view
        returns (ComponentPlan memory outgoing, ComponentPlan memory incoming)
    {
        (, , , , , address outAsset, address inAsset, , , , , , , ) = _decodeSubstitution();
        uint256 grossValue = protocol.grossBasketValue();
        outgoing = _planFor(outAsset, grossValue);
        incoming = _planFor(inAsset, grossValue);
    }

    function suggestedTrades() external view returns (TradePair[] memory trades) {
        ComponentPlan[] memory plans = this.currentPlan();
        uint256 sells;
        uint256 buys;
        for (uint256 i = 0; i < plans.length; ++i) {
            if (plans[i].valueDelta < 0) sells++;
            if (plans[i].valueDelta > 0) buys++;
        }
        uint256 maxPairs = sells < buys ? sells : buys;
        trades = new TradePair[](maxPairs);
        if (maxPairs == 0) return trades;

        uint256 cursor;
        bool[] memory usedBuy = new bool[](plans.length);
        for (uint256 i = 0; i < plans.length && cursor < maxPairs; ++i) {
            if (plans[i].valueDelta >= 0) continue;
            uint256 sellValue = uint256(-plans[i].valueDelta);
            for (uint256 j = 0; j < plans.length; ++j) {
                if (usedBuy[j] || plans[j].valueDelta <= 0) continue;
                uint256 buyValue = uint256(plans[j].valueDelta);
                uint256 matched = FixedPointMath.min(sellValue, buyValue);
                trades[cursor++] = TradePair({
                    sellAsset: plans[i].asset,
                    buyAsset: plans[j].asset,
                    sellValue: matched,
                    buyValue: matched,
                    sellAmount: FixedPointMath.amountForValue(
                        matched,
                        registry.getComponent(plans[i].asset).decimals,
                        plans[i].price
                    ),
                    buyAmount: FixedPointMath.amountForValue(
                        matched,
                        registry.getComponent(plans[j].asset).decimals,
                        plans[j].price
                    )
                });
                usedBuy[j] = true;
                break;
            }
        }
    }

    function driftReport(
        address asset
    )
        external
        view
        returns (
            uint256 observedWeightBps,
            uint256 targetWeightBps,
            uint256 driftBps,
            bool withinLimit
        )
    {
        ComponentPlan memory plan = _planFor(asset, protocol.grossBasketValue());
        observedWeightBps = plan.currentValue == 0
            ? 0
            : FixedPointMath.mulDiv(plan.currentValue, 10_000, protocol.grossBasketValue());
        targetWeightBps = plan.targetWeightBps;
        driftBps = observedWeightBps > targetWeightBps
            ? observedWeightBps - targetWeightBps
            : targetWeightBps - observedWeightBps;
        withinLimit = driftBps <= registry.getComponent(asset).maxDriftBps;
    }

    function rebalanceCostEstimate(
        uint16 slippageBps,
        uint16 keeperFeeBps
    ) external view returns (uint256 grossTradeValue, uint256 slippageCost, uint256 keeperFee) {
        ComponentPlan[] memory plans = this.currentPlan();
        for (uint256 i = 0; i < plans.length; ++i) {
            if (plans[i].valueDelta < 0) grossTradeValue += uint256(-plans[i].valueDelta);
        }
        slippageCost = grossTradeValue.bps(slippageBps);
        keeperFee = grossTradeValue.bps(keeperFeeBps);
    }

    function _planFor(
        address asset,
        uint256 grossValue
    ) internal view returns (ComponentPlan memory plan) {
        ComponentConfig memory component = registry.getComponent(asset);
        uint256 balance = IERC20(asset).balanceOf(address(protocol));
        uint256 price = oracle.getPrice(asset);
        uint256 value = FixedPointMath.valueOf(balance, component.decimals, price);
        uint256 targetValue = grossValue.bps(component.targetWeightBps);
        int256 delta = value >= targetValue
            ? -int256(value - targetValue)
            : int256(targetValue - value);
        plan = ComponentPlan({
            asset: asset,
            balance: balance,
            price: price,
            currentValue: value,
            targetValue: targetValue,
            valueDelta: delta,
            currentWeightBps: component.weightBps,
            targetWeightBps: component.targetWeightBps,
            status: component.status
        });
    }

    function _decodeSubstitution()
        internal
        view
        returns (
            uint64 nonce,
            uint8 state,
            uint40 announcedAt,
            uint40 executableAt,
            uint40 expiresAt,
            address outgoing,
            address incoming,
            uint16 outgoingWeightBps,
            uint16 incomingWeightBps,
            uint256 outgoingBalanceSnapshot,
            uint256 incomingRequiredValue,
            uint256 incomingReceived,
            bytes32 memoHash,
            bool active
        )
    {
        (
            nonce,
            state,
            outgoing,
            incoming,
            outgoingWeightBps,
            incomingWeightBps,
            announcedAt,
            executableAt,
            expiresAt,
            outgoingBalanceSnapshot,
            incomingRequiredValue,
            incomingReceived,
            memoHash
        ) = _rawSubstitution();
        active = state == 1 || state == 2;
    }

    function _rawSubstitution()
        internal
        view
        returns (
            uint64 nonce,
            uint8 state,
            address outgoing,
            address incoming,
            uint16 outgoingWeightBps,
            uint16 incomingWeightBps,
            uint40 announcedAt,
            uint40 executableAt,
            uint40 expiresAt,
            uint256 outgoingBalanceSnapshot,
            uint256 incomingRequiredValue,
            uint256 incomingReceived,
            bytes32 memoHash
        )
    {
        SubstitutionPlanLike memory plan = _substitutionLike();
        return (
            plan.nonce,
            plan.state,
            plan.outgoing,
            plan.incoming,
            plan.outgoingWeightBps,
            plan.incomingWeightBps,
            plan.announcedAt,
            plan.executableAt,
            plan.expiresAt,
            plan.outgoingBalanceSnapshot,
            plan.incomingRequiredValue,
            plan.incomingReceived,
            plan.memoHash
        );
    }

    struct SubstitutionPlanLike {
        uint64 nonce;
        uint8 state;
        address outgoing;
        address incoming;
        uint16 outgoingWeightBps;
        uint16 incomingWeightBps;
        uint40 announcedAt;
        uint40 executableAt;
        uint40 expiresAt;
        uint256 outgoingBalanceSnapshot;
        uint256 incomingRequiredValue;
        uint256 incomingReceived;
        bytes32 memoHash;
    }

    function _substitutionLike() internal view returns (SubstitutionPlanLike memory out) {
        (
            uint64 nonce,
            uint8 state,
            address outgoing,
            address incoming,
            uint16 outgoingWeightBps,
            uint16 incomingWeightBps,
            uint40 announcedAt,
            uint40 executableAt,
            uint40 expiresAt,
            uint256 outgoingBalanceSnapshot,
            uint256 incomingRequiredValue,
            uint256 incomingReceived,
            bytes32 memoHash
        ) = abi.decode(
                abi.encode(protocol.currentSubstitution()),
                (
                    uint64,
                    uint8,
                    address,
                    address,
                    uint16,
                    uint16,
                    uint40,
                    uint40,
                    uint40,
                    uint256,
                    uint256,
                    uint256,
                    bytes32
                )
            );
        out = SubstitutionPlanLike({
            nonce: nonce,
            state: state,
            outgoing: outgoing,
            incoming: incoming,
            outgoingWeightBps: outgoingWeightBps,
            incomingWeightBps: incomingWeightBps,
            announcedAt: announcedAt,
            executableAt: executableAt,
            expiresAt: expiresAt,
            outgoingBalanceSnapshot: outgoingBalanceSnapshot,
            incomingRequiredValue: incomingRequiredValue,
            incomingReceived: incomingReceived,
            memoHash: memoHash
        });
    }
}
