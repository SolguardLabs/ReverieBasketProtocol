// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FixedPointMath} from "./FixedPointMath.sol";
import {ReverieErrors} from "../errors/ReverieErrors.sol";

library ScheduleMath {
    using FixedPointMath for uint256;

    function validateWindow(
        uint40 delaySeconds,
        uint40 ttlSeconds,
        uint40 minDelay,
        uint40 maxTtl
    ) internal pure {
        if (delaySeconds < minDelay) revert ReverieErrors.InvalidDelay(delaySeconds);
        if (ttlSeconds == 0 || ttlSeconds > maxTtl) revert ReverieErrors.InvalidDelay(ttlSeconds);
    }

    function executableAt(uint40 delaySeconds) internal view returns (uint40) {
        return uint40(block.timestamp) + delaySeconds;
    }

    function expiresAt(uint40 delaySeconds, uint40 ttlSeconds) internal view returns (uint40) {
        return uint40(block.timestamp) + delaySeconds + ttlSeconds;
    }

    function requireExecutable(uint40 executableAt_, uint40 expiresAt_) internal view {
        if (block.timestamp < executableAt_) {
            revert ReverieErrors.ScheduleNotExecutable(block.timestamp, executableAt_);
        }
        if (expiresAt_ != 0 && block.timestamp > expiresAt_) {
            revert ReverieErrors.ScheduleExpired(block.timestamp, expiresAt_);
        }
    }

    function substitutionRequirement(
        uint256 totalSupply,
        uint16 incomingWeightBps,
        uint16 maxShortfallBps
    ) internal pure returns (uint256 requiredValue, uint256 minimumValue) {
        requiredValue = totalSupply.bps(incomingWeightBps);
        minimumValue = requiredValue - requiredValue.bps(maxShortfallBps);
    }

    function healthFactorWad(
        uint256 availableValue,
        uint256 requiredValue
    ) internal pure returns (uint256) {
        if (requiredValue == 0) return type(uint256).max;
        return availableValue.divWadDown(requiredValue);
    }

    function componentHash(
        address[] memory assets,
        uint16[] memory weights
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(assets, weights));
    }
}
