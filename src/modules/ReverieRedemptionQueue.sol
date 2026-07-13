// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReverieRoles} from "../access/ReverieRoles.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IReverieBasketToken} from "../interfaces/IReverieBasketToken.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {ReverieErrors} from "../errors/ReverieErrors.sol";

contract ReverieRedemptionQueue is ReverieRoles {
    using SafeTransferLib for address;
    using FixedPointMath for uint256;

    enum RequestState {
        None,
        Pending,
        Cancelled,
        Settled
    }

    struct RedemptionRequest {
        uint64 id;
        address owner;
        address receiver;
        uint256 shares;
        uint256 minValue;
        uint40 requestedAt;
        uint40 executableAt;
        RequestState state;
    }

    IReverieBasketToken public immutable basketToken;
    IERC20 public immutable settlementAsset;
    address public settlementVault;
    uint40 public minDelay = 30 minutes;
    uint64 private _nextId = 1;

    mapping(uint64 id => RedemptionRequest request) private _requests;
    mapping(address owner => uint64[] ids) private _accountRequests;

    event SettlementVaultUpdated(address indexed oldVault, address indexed newVault);
    event MinDelayUpdated(uint40 oldDelay, uint40 newDelay);
    event RedemptionRequested(
        uint64 indexed id,
        address indexed owner,
        address indexed receiver,
        uint256 shares,
        uint256 minValue,
        uint40 executableAt
    );
    event RedemptionCancelled(uint64 indexed id, address indexed owner);
    event RedemptionSettled(
        uint64 indexed id,
        address indexed receiver,
        uint256 shares,
        uint256 valuePaid
    );

    constructor(
        address admin,
        IReverieBasketToken basketToken_,
        IERC20 settlementAsset_,
        address settlementVault_
    ) ReverieRoles(admin) {
        if (address(basketToken_) == address(0) || address(settlementAsset_) == address(0)) {
            revert ReverieErrors.ZeroAddress();
        }
        if (settlementVault_ == address(0)) revert ReverieErrors.ZeroAddress();
        basketToken = basketToken_;
        settlementAsset = settlementAsset_;
        settlementVault = settlementVault_;
    }

    function setSettlementVault(address newVault) external onlyRole(GOVERNOR_ROLE) {
        if (newVault == address(0)) revert ReverieErrors.ZeroAddress();
        address old = settlementVault;
        settlementVault = newVault;
        emit SettlementVaultUpdated(old, newVault);
    }

    function setMinDelay(uint40 newDelay) external onlyRole(RISK_MANAGER_ROLE) {
        if (newDelay > 7 days) revert ReverieErrors.InvalidDelay(newDelay);
        uint40 old = minDelay;
        minDelay = newDelay;
        emit MinDelayUpdated(old, newDelay);
    }

    function requestRedemption(
        uint256 shares,
        uint256 minValue,
        address receiver
    ) external returns (uint64 id) {
        if (shares == 0) revert ReverieErrors.InvalidAmount();
        if (receiver == address(0)) revert ReverieErrors.ZeroAddress();

        basketToken.transferFrom(msg.sender, address(this), shares);
        id = _nextId++;
        uint40 executableAt = uint40(block.timestamp) + minDelay;
        _requests[id] = RedemptionRequest({
            id: id,
            owner: msg.sender,
            receiver: receiver,
            shares: shares,
            minValue: minValue,
            requestedAt: uint40(block.timestamp),
            executableAt: executableAt,
            state: RequestState.Pending
        });
        _accountRequests[msg.sender].push(id);
        emit RedemptionRequested(id, msg.sender, receiver, shares, minValue, executableAt);
    }

    function cancel(uint64 id) external {
        RedemptionRequest storage request = _requests[id];
        if (request.state != RequestState.Pending)
            revert ReverieErrors.InvalidScheduleState(uint8(request.state));
        if (request.owner != msg.sender && !hasRole(GUARDIAN_ROLE, msg.sender)) {
            revert ReverieErrors.Unauthorized(msg.sender, GUARDIAN_ROLE);
        }
        request.state = RequestState.Cancelled;
        basketToken.transfer(request.owner, request.shares);
        emit RedemptionCancelled(id, request.owner);
    }

    function settle(
        uint64 id,
        uint256 navPerShareWad
    ) external onlyRole(KEEPER_ROLE) returns (uint256 valuePaid) {
        RedemptionRequest storage request = _requests[id];
        if (request.state != RequestState.Pending)
            revert ReverieErrors.InvalidScheduleState(uint8(request.state));
        if (block.timestamp < request.executableAt) {
            revert ReverieErrors.ScheduleNotExecutable(block.timestamp, request.executableAt);
        }

        valuePaid = request.shares.mulWadDown(navPerShareWad);
        if (valuePaid < request.minValue) {
            revert ReverieErrors.SubstitutionInventoryShortfall(
                address(settlementAsset),
                valuePaid,
                request.minValue
            );
        }
        request.state = RequestState.Settled;
        basketToken.burn(address(this), request.shares);
        address(settlementAsset).safeTransferFrom(settlementVault, request.receiver, valuePaid);
        emit RedemptionSettled(id, request.receiver, request.shares, valuePaid);
    }

    function previewSettlement(
        uint64 id,
        uint256 navPerShareWad
    ) external view returns (uint256 valuePaid, bool executable) {
        RedemptionRequest memory request = _requests[id];
        if (request.state != RequestState.Pending) return (0, false);
        valuePaid = request.shares.mulWadDown(navPerShareWad);
        executable = block.timestamp >= request.executableAt && valuePaid >= request.minValue;
    }

    function requestOf(uint64 id) external view returns (RedemptionRequest memory) {
        return _requests[id];
    }

    function requestsOf(address owner) external view returns (uint64[] memory ids) {
        ids = new uint64[](_accountRequests[owner].length);
        for (uint256 i = 0; i < ids.length; ++i) ids[i] = _accountRequests[owner][i];
    }

    function pendingBalance(address owner) external view returns (uint256 shares) {
        uint64[] memory ids = _accountRequests[owner];
        for (uint256 i = 0; i < ids.length; ++i) {
            RedemptionRequest memory request = _requests[ids[i]];
            if (request.state == RequestState.Pending) shares += request.shares;
        }
    }

    function nextId() external view returns (uint64) {
        return _nextId;
    }
}
