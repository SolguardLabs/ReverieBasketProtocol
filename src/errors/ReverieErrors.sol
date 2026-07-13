// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library ReverieErrors {
    error ZeroAddress();
    error InvalidAmount();
    error InvalidArrayLength();
    error InvalidComponent(address asset);
    error ComponentAlreadyListed(address asset);
    error ComponentNotListed(address asset);
    error ComponentNotActive(address asset);
    error ComponentNotRedeemable(address asset);
    error ComponentNotYielding(address asset);
    error DuplicateComponent(address asset);
    error InvalidWeightSum(uint256 sum);
    error InvalidWeight(address asset, uint256 weight);
    error InvalidFee(uint256 feeBps);
    error InvalidDelay(uint256 delaySeconds);
    error InvalidHeartbeat(uint256 heartbeat);
    error StalePrice(address asset, uint256 lastUpdated, uint256 heartbeat);
    error PriceOutOfBounds(address asset, uint256 price);
    error Unauthorized(address caller, bytes32 role);
    error RoleAlreadyGranted(address account, bytes32 role);
    error RoleNotGranted(address account, bytes32 role);
    error ProtocolPaused();
    error ScheduleActive(uint64 nonce);
    error NoActiveSchedule();
    error ScheduleNotExecutable(uint256 nowTime, uint256 executableAt);
    error ScheduleExpired(uint256 nowTime, uint256 expiresAt);
    error InvalidScheduleState(uint8 state);
    error InvalidSubstitution(address outgoing, address incoming);
    error SubstitutionInventoryShortfall(address asset, uint256 available, uint256 required);
    error InsufficientBalance(address asset, uint256 available, uint256 required);
    error SupplyUnavailable();
    error CapExceeded(address asset, uint256 balance, uint256 cap);
    error DriftLimitExceeded(address asset, uint256 observedBps, uint256 allowedBps);
    error SameAsset();
    error TransferFailed();
    error PermitExpired();
    error InvalidSigner();
}
