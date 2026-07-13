// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReverieRoles} from "../access/ReverieRoles.sol";
import {PolicySnapshot} from "../types/ReverieTypes.sol";
import {ReverieErrors} from "../errors/ReverieErrors.sol";

contract ReverieRiskPolicy is ReverieRoles {
    uint16 public maxHarvestFeeBps = 1_500;
    uint16 public maxWeightDriftBps = 700;
    uint16 public maxSubstitutionShortfallBps = 300;
    uint40 public minWeightDelay = 1 hours;
    uint40 public minSubstitutionDelay = 2 hours;
    uint40 public maxScheduleTTL = 7 days;
    bool public redemptionsPausedDuringSubstitution;

    event HarvestFeeLimitUpdated(uint16 oldValue, uint16 newValue);
    event WeightDriftLimitUpdated(uint16 oldValue, uint16 newValue);
    event SubstitutionShortfallUpdated(uint16 oldValue, uint16 newValue);
    event DelayPolicyUpdated(
        uint40 minWeightDelay,
        uint40 minSubstitutionDelay,
        uint40 maxScheduleTTL
    );
    event SubstitutionRedemptionPolicyUpdated(bool paused);

    constructor(address admin) ReverieRoles(admin) {}

    function setHarvestFeeLimit(uint16 newLimit) external onlyRole(RISK_MANAGER_ROLE) {
        if (newLimit > 3_000) revert ReverieErrors.InvalidFee(newLimit);
        uint16 old = maxHarvestFeeBps;
        maxHarvestFeeBps = newLimit;
        emit HarvestFeeLimitUpdated(old, newLimit);
    }

    function setWeightDriftLimit(uint16 newLimit) external onlyRole(RISK_MANAGER_ROLE) {
        if (newLimit > 2_500) revert ReverieErrors.InvalidWeight(address(0), newLimit);
        uint16 old = maxWeightDriftBps;
        maxWeightDriftBps = newLimit;
        emit WeightDriftLimitUpdated(old, newLimit);
    }

    function setSubstitutionShortfallLimit(uint16 newLimit) external onlyRole(RISK_MANAGER_ROLE) {
        if (newLimit > 2_000) revert ReverieErrors.InvalidWeight(address(0), newLimit);
        uint16 old = maxSubstitutionShortfallBps;
        maxSubstitutionShortfallBps = newLimit;
        emit SubstitutionShortfallUpdated(old, newLimit);
    }

    function setDelayPolicy(
        uint40 newMinWeightDelay,
        uint40 newMinSubstitutionDelay,
        uint40 newMaxScheduleTTL
    ) external onlyRole(RISK_MANAGER_ROLE) {
        if (newMaxScheduleTTL < newMinWeightDelay || newMaxScheduleTTL < newMinSubstitutionDelay) {
            revert ReverieErrors.InvalidDelay(newMaxScheduleTTL);
        }
        minWeightDelay = newMinWeightDelay;
        minSubstitutionDelay = newMinSubstitutionDelay;
        maxScheduleTTL = newMaxScheduleTTL;
        emit DelayPolicyUpdated(newMinWeightDelay, newMinSubstitutionDelay, newMaxScheduleTTL);
    }

    function setSubstitutionRedemptionPolicy(bool paused) external onlyRole(RISK_MANAGER_ROLE) {
        redemptionsPausedDuringSubstitution = paused;
        emit SubstitutionRedemptionPolicyUpdated(paused);
    }

    function snapshot() external view returns (PolicySnapshot memory) {
        return
            PolicySnapshot({
                maxHarvestFeeBps: maxHarvestFeeBps,
                maxWeightDriftBps: maxWeightDriftBps,
                maxSubstitutionShortfallBps: maxSubstitutionShortfallBps,
                minWeightDelay: minWeightDelay,
                minSubstitutionDelay: minSubstitutionDelay,
                maxScheduleTTL: maxScheduleTTL,
                redemptionsPausedDuringSubstitution: redemptionsPausedDuringSubstitution
            });
    }
}
