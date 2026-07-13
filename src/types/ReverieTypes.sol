// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

enum ComponentStatus {
    Unlisted,
    Active,
    PendingAdd,
    PendingRemove,
    Retired
}

enum ScheduleState {
    Idle,
    Announced,
    Funded,
    Applied,
    Cancelled
}

struct ComponentConfig {
    address asset;
    uint8 decimals;
    uint16 weightBps;
    uint16 targetWeightBps;
    uint16 maxDriftBps;
    uint16 harvestFeeBps;
    uint96 maxBalance;
    ComponentStatus status;
    bool redeemable;
    bool yieldEnabled;
    uint40 listedAt;
    uint40 updatedAt;
}

struct AssetAmount {
    address asset;
    uint256 amount;
}

struct ComponentValue {
    address asset;
    uint256 balance;
    uint256 price;
    uint256 value;
    uint16 weightBps;
    ComponentStatus status;
}

struct MintQuote {
    uint256 basketAmount;
    uint256 grossValue;
    AssetAmount[] deposits;
}

struct RedeemQuote {
    uint256 shares;
    uint256 supplyBasis;
    bool selectedLane;
    bool transitionWindow;
    AssetAmount[] outputs;
}

struct HarvestReport {
    address asset;
    address source;
    uint256 grossAmount;
    uint256 feeAmount;
    uint256 netAmount;
    bytes32 reportHash;
    uint40 timestamp;
}

struct WeightUpdate {
    uint64 nonce;
    ScheduleState state;
    uint40 announcedAt;
    uint40 executableAt;
    uint40 expiresAt;
    bytes32 componentHash;
    bytes32 memoHash;
}

struct SubstitutionPlan {
    uint64 nonce;
    ScheduleState state;
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

struct NavReport {
    uint256 totalSupply;
    uint256 grossValue;
    uint256 accountingValue;
    uint256 backedSupply;
    uint256 navPerShare;
    uint256 accountingNavPerShare;
    bool transitionWindow;
}

struct AccountSnapshot {
    address account;
    uint256 shares;
    uint256 grossClaimValue;
    uint256 accountingClaimValue;
    AssetAmount[] activeClaims;
}

struct PolicySnapshot {
    uint16 maxHarvestFeeBps;
    uint16 maxWeightDriftBps;
    uint16 maxSubstitutionShortfallBps;
    uint40 minWeightDelay;
    uint40 minSubstitutionDelay;
    uint40 maxScheduleTTL;
    bool redemptionsPausedDuringSubstitution;
}
