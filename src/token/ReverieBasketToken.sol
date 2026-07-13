// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IReverieBasketToken} from "../interfaces/IReverieBasketToken.sol";
import {ReverieErrors} from "../errors/ReverieErrors.sol";

contract ReverieBasketToken is IReverieBasketToken {
    string private _name;
    string private _symbol;
    uint8 private constant _DECIMALS = 18;

    uint256 private _totalSupply;
    address public immutable override vault;

    mapping(address account => uint256 balance) private _balances;
    mapping(address owner => mapping(address spender => uint256 allowance_)) private _allowances;

    mapping(address owner => uint256 nonce) public nonces;
    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );

    constructor(string memory name_, string memory symbol_, address vault_) {
        if (vault_ == address(0)) revert ReverieErrors.ZeroAddress();
        _name = name_;
        _symbol = symbol_;
        vault = vault_;

        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(name_)),
                keccak256(bytes("1")),
                chainId,
                address(this)
            )
        );
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert ReverieErrors.Unauthorized(msg.sender, keccak256("VAULT"));
        _;
    }

    function name() external view override returns (string memory) {
        return _name;
    }

    function symbol() external view override returns (string memory) {
        return _symbol;
    }

    function decimals() external pure override returns (uint8) {
        return _DECIMALS;
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external override returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount)
                revert ReverieErrors.InsufficientBalance(address(this), allowed, amount);
            unchecked {
                _allowances[from][msg.sender] = allowed - amount;
            }
            emit Approval(from, msg.sender, _allowances[from][msg.sender]);
        }
        _transfer(from, to, amount);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender] + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        uint256 current = _allowances[msg.sender][spender];
        if (current < subtractedValue) {
            revert ReverieErrors.InsufficientBalance(address(this), current, subtractedValue);
        }
        unchecked {
            _approve(msg.sender, spender, current - subtractedValue);
        }
        return true;
    }

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (block.timestamp > deadline) revert ReverieErrors.PermitExpired();
        uint256 nonce = nonces[owner]++;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline))
            )
        );
        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0) || recovered != owner) revert ReverieErrors.InvalidSigner();
        _approve(owner, spender, value);
    }

    function mint(address receiver, uint256 amount) external override onlyVault {
        if (receiver == address(0)) revert ReverieErrors.ZeroAddress();
        if (amount == 0) revert ReverieErrors.InvalidAmount();
        _totalSupply += amount;
        _balances[receiver] += amount;
        emit Transfer(address(0), receiver, amount);
    }

    function burn(address account, uint256 amount) external override onlyVault {
        if (account == address(0)) revert ReverieErrors.ZeroAddress();
        if (amount == 0) revert ReverieErrors.InvalidAmount();
        uint256 balance = _balances[account];
        if (balance < amount)
            revert ReverieErrors.InsufficientBalance(address(this), balance, amount);
        unchecked {
            _balances[account] = balance - amount;
            _totalSupply -= amount;
        }
        emit Transfer(account, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0) || from == address(0)) revert ReverieErrors.ZeroAddress();
        if (amount == 0) revert ReverieErrors.InvalidAmount();
        uint256 balance = _balances[from];
        if (balance < amount)
            revert ReverieErrors.InsufficientBalance(address(this), balance, amount);
        unchecked {
            _balances[from] = balance - amount;
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        if (owner == address(0) || spender == address(0)) revert ReverieErrors.ZeroAddress();
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}
