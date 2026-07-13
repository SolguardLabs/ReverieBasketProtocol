// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ComponentRegistry} from "../core/ComponentRegistry.sol";
import {ReverieBasketProtocol} from "../vault/ReverieBasketProtocol.sol";
import {ReveriePriceOracle} from "../oracle/ReveriePriceOracle.sol";
import {AssetAmount, ComponentConfig, ComponentValue, MintQuote, NavReport, RedeemQuote, SubstitutionPlan, WeightUpdate} from "../types/ReverieTypes.sol";

contract ReverieLens {
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

    function overview()
        external
        view
        returns (
            address token,
            address treasury,
            bool paused,
            NavReport memory report,
            WeightUpdate memory weightUpdate,
            SubstitutionPlan memory substitution
        )
    {
        token = protocol.token();
        treasury = protocol.treasury();
        paused = protocol.paused();
        report = protocol.navReport();
        weightUpdate = protocol.currentWeightUpdate();
        substitution = protocol.currentSubstitution();
    }

    function quoteMint(uint256 basketAmount) external view returns (MintQuote memory) {
        return protocol.previewMint(basketAmount);
    }

    function quoteRedeem(uint256 shares) external view returns (RedeemQuote memory) {
        return protocol.previewRedeem(shares);
    }

    function quoteSelectedRedeem(
        uint256 shares,
        address[] calldata assets
    ) external view returns (RedeemQuote memory) {
        return protocol.previewInKindRedeem(shares, assets);
    }

    function components() external view returns (ComponentConfig[] memory configs) {
        address[] memory assets = registry.allComponents();
        configs = new ComponentConfig[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            configs[i] = registry.getComponent(assets[i]);
        }
    }

    function activeComponents() external view returns (ComponentValue[] memory values) {
        address[] memory assets = registry.activeComponents();
        values = new ComponentValue[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            values[i] = protocol.componentValue(assets[i]);
        }
    }

    function backingComponents() external view returns (ComponentValue[] memory values) {
        address[] memory assets = registry.backingComponents();
        values = new ComponentValue[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            values[i] = protocol.componentValue(assets[i]);
        }
    }

    function redeemableAssets() external view returns (address[] memory) {
        return registry.redeemableComponents();
    }

    function pendingWeights()
        external
        view
        returns (address[] memory assets, uint16[] memory weights)
    {
        return protocol.pendingWeightAssets();
    }

    function selectedClaimsForAllRedeemable(
        uint256 shares
    ) external view returns (AssetAmount[] memory) {
        address[] memory assets = registry.redeemableComponents();
        RedeemQuote memory quote = protocol.previewInKindRedeem(shares, assets);
        return quote.outputs;
    }

    function oracleRecords(
        address[] calldata assets
    )
        external
        view
        returns (uint256[] memory prices, uint40[] memory timestamps, bool[] memory fresh)
    {
        prices = new uint256[](assets.length);
        timestamps = new uint40[](assets.length);
        fresh = new bool[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            prices[i] = oracle.getPrice(assets[i]);
            timestamps[i] = oracle.priceTimestamp(assets[i]);
            fresh[i] = oracle.priceIsFresh(assets[i]);
        }
    }
}
