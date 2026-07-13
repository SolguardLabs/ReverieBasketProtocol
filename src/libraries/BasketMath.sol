// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FixedPointMath} from "./FixedPointMath.sol";
import {ComponentConfig, ComponentStatus, AssetAmount} from "../types/ReverieTypes.sol";
import {ReverieErrors} from "../errors/ReverieErrors.sol";

library BasketMath {
    using FixedPointMath for uint256;

    uint256 internal constant BPS = 10_000;

    function validateWeights(address[] memory assets, uint16[] memory weights) internal pure {
        if (assets.length == 0 || assets.length != weights.length) {
            revert ReverieErrors.InvalidArrayLength();
        }

        uint256 sum;
        for (uint256 i = 0; i < assets.length; ++i) {
            if (assets[i] == address(0)) revert ReverieErrors.ZeroAddress();
            if (weights[i] == 0) revert ReverieErrors.InvalidWeight(assets[i], weights[i]);
            for (uint256 j = i + 1; j < assets.length; ++j) {
                if (assets[i] == assets[j]) revert ReverieErrors.DuplicateComponent(assets[i]);
            }
            sum += weights[i];
        }

        if (sum != BPS) revert ReverieErrors.InvalidWeightSum(sum);
    }

    function validateTargetWeights(address[] memory assets, uint16[] memory weights) internal pure {
        if (assets.length == 0 || assets.length != weights.length) {
            revert ReverieErrors.InvalidArrayLength();
        }

        uint256 sum;
        for (uint256 i = 0; i < assets.length; ++i) {
            if (assets[i] == address(0)) revert ReverieErrors.ZeroAddress();
            for (uint256 j = i + 1; j < assets.length; ++j) {
                if (assets[i] == assets[j]) revert ReverieErrors.DuplicateComponent(assets[i]);
            }
            sum += weights[i];
        }

        if (sum != BPS) revert ReverieErrors.InvalidWeightSum(sum);
    }

    function quoteDeposits(
        ComponentConfig[] memory components,
        uint256[] memory prices,
        uint256 basketAmount
    ) internal pure returns (AssetAmount[] memory deposits, uint256 grossValue) {
        if (components.length != prices.length) revert ReverieErrors.InvalidArrayLength();
        grossValue = basketAmount;
        deposits = new AssetAmount[](components.length);
        for (uint256 i = 0; i < components.length; ++i) {
            ComponentConfig memory component = components[i];
            if (component.status != ComponentStatus.Active) {
                revert ReverieErrors.ComponentNotActive(component.asset);
            }
            uint256 value = grossValue.bps(component.weightBps);
            deposits[i] = AssetAmount({
                asset: component.asset,
                amount: FixedPointMath.amountForValue(value, component.decimals, prices[i])
            });
        }
    }

    function quoteProRata(
        address[] memory assets,
        uint256[] memory balances,
        uint256 shares,
        uint256 supply
    ) internal pure returns (AssetAmount[] memory outputs) {
        if (assets.length != balances.length) revert ReverieErrors.InvalidArrayLength();
        if (supply == 0) revert ReverieErrors.SupplyUnavailable();
        outputs = new AssetAmount[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            outputs[i] = AssetAmount({
                asset: assets[i],
                amount: FixedPointMath.mulDiv(balances[i], shares, supply)
            });
        }
    }

    function componentValue(
        uint256 balance,
        uint8 decimals,
        uint256 price
    ) internal pure returns (uint256) {
        return FixedPointMath.valueOf(balance, decimals, price);
    }

    function totalValue(
        uint256[] memory balances,
        uint8[] memory decimals,
        uint256[] memory prices
    ) internal pure returns (uint256 value) {
        if (balances.length != decimals.length || balances.length != prices.length) {
            revert ReverieErrors.InvalidArrayLength();
        }
        for (uint256 i = 0; i < balances.length; ++i) {
            value += FixedPointMath.valueOf(balances[i], decimals[i], prices[i]);
        }
    }

    function observedWeightBps(uint256 value, uint256 totalValue_) internal pure returns (uint256) {
        if (totalValue_ == 0) return 0;
        return FixedPointMath.mulDiv(value, BPS, totalValue_);
    }

    function driftBps(uint256 observed, uint256 target) internal pure returns (uint256) {
        return observed > target ? observed - target : target - observed;
    }

    function enforceBalanceCap(ComponentConfig memory component, uint256 balance) internal pure {
        uint256 cap = uint256(component.maxBalance);
        if (cap != 0 && balance > cap) {
            revert ReverieErrors.CapExceeded(component.asset, balance, cap);
        }
    }

    function splitFee(
        uint256 amount,
        uint256 feeBps
    ) internal pure returns (uint256 net, uint256 fee) {
        fee = amount.bps(feeBps);
        net = amount - fee;
    }

    function requiredValueForWeight(
        uint256 totalSupply,
        uint256 weightBps
    ) internal pure returns (uint256) {
        return totalSupply.bps(weightBps);
    }

    function shortfallBps(
        uint256 availableValue,
        uint256 requiredValue
    ) internal pure returns (uint256) {
        if (requiredValue == 0 || availableValue >= requiredValue) return 0;
        return FixedPointMath.mulDiv(requiredValue - availableValue, BPS, requiredValue);
    }
}
