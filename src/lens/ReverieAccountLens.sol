// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {ReverieBasketProtocol} from "../vault/ReverieBasketProtocol.sol";
import {ComponentRegistry} from "../core/ComponentRegistry.sol";
import {AccountSnapshot, AssetAmount, ComponentConfig} from "../types/ReverieTypes.sol";

contract ReverieAccountLens {
    ReverieBasketProtocol public immutable protocol;
    ComponentRegistry public immutable registry;

    constructor(ReverieBasketProtocol protocol_, ComponentRegistry registry_) {
        protocol = protocol_;
        registry = registry_;
    }

    function snapshot(address account) external view returns (AccountSnapshot memory) {
        return protocol.accountSnapshot(account);
    }

    function walletComponentBalances(
        address account
    ) external view returns (AssetAmount[] memory balances) {
        address[] memory assets = registry.allComponents();
        balances = new AssetAmount[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            balances[i] = AssetAmount({
                asset: assets[i],
                amount: IERC20(assets[i]).balanceOf(account)
            });
        }
    }

    function walletAllowances(
        address account,
        address spender
    ) external view returns (AssetAmount[] memory allowances_) {
        address[] memory assets = registry.allComponents();
        allowances_ = new AssetAmount[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            allowances_[i] = AssetAmount({
                asset: assets[i],
                amount: IERC20(assets[i]).allowance(account, spender)
            });
        }
    }

    function requiredApprovals(
        uint256 basketAmount
    ) external view returns (AssetAmount[] memory approvals) {
        approvals = protocol.previewMint(basketAmount).deposits;
    }

    function activeClaimFor(
        address account,
        address asset
    ) external view returns (uint256 amount, uint256 assetIndex, bool found) {
        AccountSnapshot memory accountSnapshot = protocol.accountSnapshot(account);
        for (uint256 i = 0; i < accountSnapshot.activeClaims.length; ++i) {
            if (accountSnapshot.activeClaims[i].asset == asset) {
                return (accountSnapshot.activeClaims[i].amount, i, true);
            }
        }
        return (0, 0, false);
    }

    function componentMetadata(
        address[] calldata assets
    ) external view returns (ComponentConfig[] memory configs) {
        configs = new ComponentConfig[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            configs[i] = registry.getComponent(assets[i]);
        }
    }
}
