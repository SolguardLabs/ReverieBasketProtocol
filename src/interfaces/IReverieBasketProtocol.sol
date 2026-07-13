// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccountSnapshot, AssetAmount, ComponentValue, HarvestReport, MintQuote, NavReport, RedeemQuote, SubstitutionPlan, WeightUpdate} from "../types/ReverieTypes.sol";

interface IReverieBasketProtocol {
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ProtocolPaused(address indexed caller);
    event ProtocolUnpaused(address indexed caller);
    event Minted(
        address indexed caller,
        address indexed receiver,
        uint256 shares,
        uint256 components
    );
    event Redeemed(
        address indexed caller,
        address indexed receiver,
        uint256 shares,
        uint256 components
    );
    event InKindRedeemed(
        address indexed caller,
        address indexed receiver,
        uint256 shares,
        uint256 supplyBasis,
        uint256 components
    );
    event Harvested(
        address indexed asset,
        address indexed source,
        uint256 grossAmount,
        uint256 feeAmount,
        uint256 netAmount,
        bytes32 reportHash
    );
    event WeightUpdateAnnounced(
        uint64 indexed nonce,
        uint40 executableAt,
        uint40 expiresAt,
        bytes32 componentHash,
        bytes32 memoHash
    );
    event WeightUpdateApplied(uint64 indexed nonce, bytes32 componentHash);
    event WeightUpdateCancelled(uint64 indexed nonce);
    event SubstitutionAnnounced(
        uint64 indexed nonce,
        address indexed outgoing,
        address indexed incoming,
        uint16 incomingWeightBps,
        uint40 executableAt,
        uint40 expiresAt,
        bytes32 memoHash
    );
    event SubstitutionInventoryReceived(
        uint64 indexed nonce,
        address indexed incoming,
        address indexed source,
        uint256 amount,
        uint256 value
    );
    event SubstitutionCompleted(
        uint64 indexed nonce,
        address indexed outgoing,
        address indexed incoming
    );
    event SubstitutionCancelled(
        uint64 indexed nonce,
        address indexed outgoing,
        address indexed incoming
    );
    event RetiredAssetSwept(address indexed asset, address indexed receiver, uint256 amount);

    function token() external view returns (address);
    function treasury() external view returns (address);
    function paused() external view returns (bool);
    function setTreasury(address newTreasury) external;
    function pause() external;
    function unpause() external;

    function mint(uint256 basketAmount, address receiver) external returns (uint256 minted);
    function redeem(
        uint256 shares,
        address receiver
    ) external returns (AssetAmount[] memory outputs);
    function redeemInKind(
        uint256 shares,
        address[] calldata requestedAssets,
        address receiver
    ) external returns (AssetAmount[] memory outputs);

    function previewMint(uint256 basketAmount) external view returns (MintQuote memory quote);
    function previewRedeem(uint256 shares) external view returns (RedeemQuote memory quote);
    function previewInKindRedeem(
        uint256 shares,
        address[] calldata requestedAssets
    ) external view returns (RedeemQuote memory quote);

    function harvest(
        address asset,
        uint256 amount,
        address source,
        bytes32 reportHash
    ) external returns (HarvestReport memory report);

    function announceWeightUpdate(
        address[] calldata assets,
        uint16[] calldata targetWeights,
        uint40 delaySeconds,
        uint40 ttlSeconds,
        bytes32 memoHash
    ) external;
    function applyWeightUpdate() external;
    function cancelWeightUpdate() external;

    function announceSubstitution(
        address outgoing,
        address incoming,
        uint40 delaySeconds,
        uint40 ttlSeconds,
        bytes32 memoHash
    ) external;
    function receiveSubstitutionInventory(uint256 amount, address source) external;
    function completeSubstitution() external;
    function cancelSubstitution() external;
    function sweepRetiredAsset(address asset, address receiver, uint256 amount) external;

    function grossBasketValue() external view returns (uint256);
    function accountingBasketValue() external view returns (uint256);
    function backedSupply() external view returns (uint256);
    function navPerShare() external view returns (uint256);
    function accountingNavPerShare() external view returns (uint256);
    function navReport() external view returns (NavReport memory report);
    function componentValue(address asset) external view returns (ComponentValue memory value);
    function componentValues(
        address[] calldata assets
    ) external view returns (ComponentValue[] memory values);
    function accountSnapshot(
        address account
    ) external view returns (AccountSnapshot memory snapshot);
    function currentWeightUpdate() external view returns (WeightUpdate memory);
    function pendingWeightAssets()
        external
        view
        returns (address[] memory assets, uint16[] memory weights);
    function currentSubstitution() external view returns (SubstitutionPlan memory);
    function lastSubstitution() external view returns (SubstitutionPlan memory);
    function lastHarvest(address asset) external view returns (HarvestReport memory);
}
