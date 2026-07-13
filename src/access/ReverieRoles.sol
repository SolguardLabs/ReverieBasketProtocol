// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReverieErrors} from "../errors/ReverieErrors.sol";

contract ReverieRoles {
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant GOVERNOR_ROLE = keccak256("REVERIE_GOVERNOR_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("REVERIE_KEEPER_ROLE");
    bytes32 public constant REBALANCER_ROLE = keccak256("REVERIE_REBALANCER_ROLE");
    bytes32 public constant STRATEGIST_ROLE = keccak256("REVERIE_STRATEGIST_ROLE");
    bytes32 public constant RISK_MANAGER_ROLE = keccak256("REVERIE_RISK_MANAGER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("REVERIE_GUARDIAN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("REVERIE_PAUSER_ROLE");

    mapping(bytes32 role => mapping(address account => bool granted)) private _roles;

    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    constructor(address initialAdmin) {
        if (initialAdmin == address(0)) revert ReverieErrors.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(GOVERNOR_ROLE, initialAdmin);
        _grantRole(KEEPER_ROLE, initialAdmin);
        _grantRole(REBALANCER_ROLE, initialAdmin);
        _grantRole(STRATEGIST_ROLE, initialAdmin);
        _grantRole(RISK_MANAGER_ROLE, initialAdmin);
        _grantRole(GUARDIAN_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
    }

    modifier onlyRole(bytes32 role) {
        _checkRole(role, msg.sender);
        _;
    }

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role][account];
    }

    function grantRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert ReverieErrors.ZeroAddress();
        if (_roles[role][account]) revert ReverieErrors.RoleAlreadyGranted(account, role);
        _grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_roles[role][account]) revert ReverieErrors.RoleNotGranted(account, role);
        _roles[role][account] = false;
        emit RoleRevoked(role, account, msg.sender);
    }

    function renounceRole(bytes32 role) external {
        if (!_roles[role][msg.sender]) revert ReverieErrors.RoleNotGranted(msg.sender, role);
        _roles[role][msg.sender] = false;
        emit RoleRevoked(role, msg.sender, msg.sender);
    }

    function _checkRole(bytes32 role, address account) internal view {
        if (!_roles[role][account]) revert ReverieErrors.Unauthorized(account, role);
    }

    function _grantRole(bytes32 role, address account) internal {
        _roles[role][account] = true;
        emit RoleGranted(role, account, msg.sender);
    }
}
