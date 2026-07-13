// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReverieRoles} from "../access/ReverieRoles.sol";
import {ComponentRegistry} from "../core/ComponentRegistry.sol";
import {ReverieErrors} from "../errors/ReverieErrors.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";
import {BasketMath} from "../libraries/BasketMath.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {ScheduleMath} from "../libraries/ScheduleMath.sol";
import {ReveriePriceOracle} from "../oracle/ReveriePriceOracle.sol";
import {ReverieRiskPolicy} from "../policy/ReverieRiskPolicy.sol";
import {ReverieBasketToken} from "../token/ReverieBasketToken.sol";
import {AccountSnapshot, AssetAmount, ComponentConfig, ComponentStatus, ComponentValue, HarvestReport, MintQuote, NavReport, RedeemQuote, ScheduleState, SubstitutionPlan, WeightUpdate} from "../types/ReverieTypes.sol";

contract ReverieBasketProtocol is ReverieRoles {
    using SafeTransferLib for address;
    using FixedPointMath for uint256;

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;

    ComponentRegistry public immutable registry;
    ReveriePriceOracle public immutable oracle;
    ReverieRiskPolicy public immutable riskPolicy;
    ReverieBasketToken public immutable basketToken;

    address public treasury;
    bool public paused;

    uint64 private _scheduleNonce;
    uint256 private _locked = 1;

    WeightUpdate private _weightUpdate;
    SubstitutionPlan private _substitution;
    SubstitutionPlan private _lastSubstitution;

    address[] private _pendingWeightAssets;
    uint16[] private _pendingWeightBps;

    mapping(address asset => uint256 amount) public harvestedGross;
    mapping(address asset => uint256 amount) public harvestedFees;
    mapping(address asset => HarvestReport report) private _lastHarvest;

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

    constructor(
        address admin,
        address initialTreasury,
        ComponentRegistry componentRegistry,
        ReveriePriceOracle priceOracle,
        ReverieRiskPolicy policy
    ) ReverieRoles(admin) {
        if (initialTreasury == address(0)) revert ReverieErrors.ZeroAddress();
        if (address(componentRegistry) == address(0) || address(priceOracle) == address(0)) {
            revert ReverieErrors.ZeroAddress();
        }
        if (address(policy) == address(0)) revert ReverieErrors.ZeroAddress();

        treasury = initialTreasury;
        registry = componentRegistry;
        oracle = priceOracle;
        riskPolicy = policy;
        basketToken = new ReverieBasketToken("Reverie Basket Token", "RVB", address(this));

        emit TreasuryUpdated(address(0), initialTreasury);
    }

    modifier nonReentrant() {
        if (_locked != 1) revert ReverieErrors.ProtocolPaused();
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier whenNotPaused() {
        if (paused) revert ReverieErrors.ProtocolPaused();
        _;
    }

    function token() external view returns (address) {
        return address(basketToken);
    }

    function setTreasury(address newTreasury) external onlyRole(GOVERNOR_ROLE) {
        if (newTreasury == address(0)) revert ReverieErrors.ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        paused = true;
        emit ProtocolPaused(msg.sender);
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        paused = false;
        emit ProtocolUnpaused(msg.sender);
    }

    function mint(
        uint256 basketAmount,
        address receiver
    ) external nonReentrant whenNotPaused returns (uint256 minted) {
        if (basketAmount == 0) revert ReverieErrors.InvalidAmount();
        if (receiver == address(0)) revert ReverieErrors.ZeroAddress();
        if (
            _substitution.state == ScheduleState.Announced ||
            _substitution.state == ScheduleState.Funded
        ) {
            revert ReverieErrors.ScheduleActive(_substitution.nonce);
        }

        MintQuote memory quote = previewMint(basketAmount);
        for (uint256 i = 0; i < quote.deposits.length; ++i) {
            AssetAmount memory deposit = quote.deposits[i];
            deposit.asset.safeTransferFrom(msg.sender, address(this), deposit.amount);
        }

        _validateCaps(registry.activeComponents());
        basketToken.mint(receiver, basketAmount);
        minted = basketAmount;
        emit Minted(msg.sender, receiver, basketAmount, quote.deposits.length);
    }

    function redeem(
        uint256 shares,
        address receiver
    ) external nonReentrant whenNotPaused returns (AssetAmount[] memory outputs) {
        if (shares == 0) revert ReverieErrors.InvalidAmount();
        if (receiver == address(0)) revert ReverieErrors.ZeroAddress();

        RedeemQuote memory quote = previewRedeem(shares);
        basketToken.burn(msg.sender, shares);
        _transferOutputs(receiver, quote.outputs);
        emit Redeemed(msg.sender, receiver, shares, quote.outputs.length);
        return quote.outputs;
    }

    function redeemInKind(
        uint256 shares,
        address[] calldata requestedAssets,
        address receiver
    ) external nonReentrant whenNotPaused returns (AssetAmount[] memory outputs) {
        if (shares == 0) revert ReverieErrors.InvalidAmount();
        if (receiver == address(0)) revert ReverieErrors.ZeroAddress();
        if (requestedAssets.length == 0) revert ReverieErrors.InvalidArrayLength();
        if (
            riskPolicy.redemptionsPausedDuringSubstitution() &&
            (_substitution.state == ScheduleState.Announced ||
                _substitution.state == ScheduleState.Funded)
        ) {
            revert ReverieErrors.ScheduleActive(_substitution.nonce);
        }

        RedeemQuote memory quote = previewInKindRedeem(shares, requestedAssets);
        basketToken.burn(msg.sender, shares);
        _transferOutputs(receiver, quote.outputs);
        emit InKindRedeemed(msg.sender, receiver, shares, quote.supplyBasis, quote.outputs.length);
        return quote.outputs;
    }

    function previewMint(uint256 basketAmount) public view returns (MintQuote memory quote) {
        if (basketAmount == 0) revert ReverieErrors.InvalidAmount();
        address[] memory assets = registry.activeComponents();
        ComponentConfig[] memory components = _componentConfigs(assets);
        uint256[] memory prices = _prices(assets);
        (AssetAmount[] memory deposits, uint256 grossValue) = BasketMath.quoteDeposits(
            components,
            prices,
            basketAmount
        );
        quote = MintQuote({basketAmount: basketAmount, grossValue: grossValue, deposits: deposits});
    }

    function previewRedeem(uint256 shares) public view returns (RedeemQuote memory quote) {
        if (shares == 0) revert ReverieErrors.InvalidAmount();
        uint256 supply = basketToken.totalSupply();
        address[] memory assets = registry.activeComponents();
        uint256[] memory balances = _balances(assets);
        AssetAmount[] memory outputs = BasketMath.quoteProRata(assets, balances, shares, supply);
        quote = RedeemQuote({
            shares: shares,
            supplyBasis: supply,
            selectedLane: false,
            transitionWindow: _substitution.state == ScheduleState.Announced ||
                _substitution.state == ScheduleState.Funded,
            outputs: outputs
        });
    }

    function previewInKindRedeem(
        uint256 shares,
        address[] calldata requestedAssets
    ) public view returns (RedeemQuote memory quote) {
        if (shares == 0) revert ReverieErrors.InvalidAmount();
        if (requestedAssets.length == 0) revert ReverieErrors.InvalidArrayLength();

        uint256 supplyBasis = _inKindSupplyBasis();
        AssetAmount[] memory outputs = new AssetAmount[](requestedAssets.length);
        for (uint256 i = 0; i < requestedAssets.length; ++i) {
            address asset = requestedAssets[i];
            if (!registry.isInKindRedeemable(asset))
                revert ReverieErrors.ComponentNotRedeemable(asset);
            for (uint256 j = i + 1; j < requestedAssets.length; ++j) {
                if (asset == requestedAssets[j]) revert ReverieErrors.DuplicateComponent(asset);
            }
            uint256 balance = IERC20(asset).balanceOf(address(this));
            uint256 amount = FixedPointMath.mulDiv(balance, shares, supplyBasis);
            if (amount > balance) revert ReverieErrors.InsufficientBalance(asset, balance, amount);
            outputs[i] = AssetAmount({asset: asset, amount: amount});
        }

        quote = RedeemQuote({
            shares: shares,
            supplyBasis: supplyBasis,
            selectedLane: true,
            transitionWindow: _substitution.state == ScheduleState.Announced ||
                _substitution.state == ScheduleState.Funded,
            outputs: outputs
        });
    }

    function harvest(
        address asset,
        uint256 amount,
        address source,
        bytes32 reportHash
    )
        external
        nonReentrant
        whenNotPaused
        onlyRole(KEEPER_ROLE)
        returns (HarvestReport memory report)
    {
        if (asset == address(0) || source == address(0)) revert ReverieErrors.ZeroAddress();
        if (amount == 0) revert ReverieErrors.InvalidAmount();

        ComponentConfig memory component = registry.getComponent(asset);
        if (!component.yieldEnabled) revert ReverieErrors.ComponentNotYielding(asset);
        if (component.harvestFeeBps > riskPolicy.maxHarvestFeeBps()) {
            revert ReverieErrors.InvalidFee(component.harvestFeeBps);
        }

        asset.safeTransferFrom(source, address(this), amount);
        (uint256 net, uint256 fee) = BasketMath.splitFee(amount, component.harvestFeeBps);
        if (fee != 0) asset.safeTransfer(treasury, fee);

        harvestedGross[asset] += amount;
        harvestedFees[asset] += fee;
        report = HarvestReport({
            asset: asset,
            source: source,
            grossAmount: amount,
            feeAmount: fee,
            netAmount: net,
            reportHash: reportHash,
            timestamp: uint40(block.timestamp)
        });
        _lastHarvest[asset] = report;

        _validateCaps(_singleAsset(asset));
        emit Harvested(asset, source, amount, fee, net, reportHash);
    }

    function announceWeightUpdate(
        address[] calldata assets,
        uint16[] calldata targetWeights,
        uint40 delaySeconds,
        uint40 ttlSeconds,
        bytes32 memoHash
    ) external whenNotPaused onlyRole(REBALANCER_ROLE) {
        if (_weightUpdate.state == ScheduleState.Announced) {
            revert ReverieErrors.ScheduleActive(_weightUpdate.nonce);
        }
        ScheduleMath.validateWindow(
            delaySeconds,
            ttlSeconds,
            riskPolicy.minWeightDelay(),
            riskPolicy.maxScheduleTTL()
        );
        registry.setTargetWeights(assets, targetWeights);

        delete _pendingWeightAssets;
        delete _pendingWeightBps;
        for (uint256 i = 0; i < assets.length; ++i) {
            _pendingWeightAssets.push(assets[i]);
            _pendingWeightBps.push(targetWeights[i]);
        }

        uint64 nonce = ++_scheduleNonce;
        uint40 executableAt_ = ScheduleMath.executableAt(delaySeconds);
        uint40 expiresAt_ = ScheduleMath.expiresAt(delaySeconds, ttlSeconds);
        bytes32 hash = ScheduleMath.componentHash(_pendingWeightAssets, _pendingWeightBps);
        _weightUpdate = WeightUpdate({
            nonce: nonce,
            state: ScheduleState.Announced,
            announcedAt: uint40(block.timestamp),
            executableAt: executableAt_,
            expiresAt: expiresAt_,
            componentHash: hash,
            memoHash: memoHash
        });

        emit WeightUpdateAnnounced(nonce, executableAt_, expiresAt_, hash, memoHash);
    }

    function applyWeightUpdate() external whenNotPaused onlyRole(REBALANCER_ROLE) {
        if (_weightUpdate.state != ScheduleState.Announced) revert ReverieErrors.NoActiveSchedule();
        ScheduleMath.requireExecutable(_weightUpdate.executableAt, _weightUpdate.expiresAt);

        registry.applyWeights(_pendingWeightAssets, _pendingWeightBps);
        _weightUpdate.state = ScheduleState.Applied;
        emit WeightUpdateApplied(_weightUpdate.nonce, registry.componentHash());
        delete _pendingWeightAssets;
        delete _pendingWeightBps;
        delete _weightUpdate;
    }

    function cancelWeightUpdate() external onlyRole(REBALANCER_ROLE) {
        if (_weightUpdate.state != ScheduleState.Announced) revert ReverieErrors.NoActiveSchedule();
        uint64 nonce = _weightUpdate.nonce;
        _weightUpdate.state = ScheduleState.Cancelled;
        delete _pendingWeightAssets;
        delete _pendingWeightBps;
        delete _weightUpdate;
        emit WeightUpdateCancelled(nonce);
    }

    function announceSubstitution(
        address outgoing,
        address incoming,
        uint40 delaySeconds,
        uint40 ttlSeconds,
        bytes32 memoHash
    ) external whenNotPaused onlyRole(REBALANCER_ROLE) {
        if (outgoing == address(0) || incoming == address(0)) revert ReverieErrors.ZeroAddress();
        if (outgoing == incoming) revert ReverieErrors.SameAsset();
        if (
            _substitution.state == ScheduleState.Announced ||
            _substitution.state == ScheduleState.Funded
        ) {
            revert ReverieErrors.ScheduleActive(_substitution.nonce);
        }
        ScheduleMath.validateWindow(
            delaySeconds,
            ttlSeconds,
            riskPolicy.minSubstitutionDelay(),
            riskPolicy.maxScheduleTTL()
        );

        ComponentConfig memory outgoingComponent = registry.getComponent(outgoing);
        ComponentConfig memory incomingComponent = registry.getComponent(incoming);
        if (outgoingComponent.status != ComponentStatus.Active) {
            revert ReverieErrors.ComponentNotActive(outgoing);
        }
        if (
            incomingComponent.status != ComponentStatus.PendingAdd &&
            incomingComponent.status != ComponentStatus.Retired
        ) {
            revert ReverieErrors.InvalidSubstitution(outgoing, incoming);
        }

        uint64 nonce = ++_scheduleNonce;
        uint16 incomingWeightBps = outgoingComponent.weightBps;
        (uint256 requiredValue, ) = ScheduleMath.substitutionRequirement(
            basketToken.totalSupply(),
            incomingWeightBps,
            riskPolicy.maxSubstitutionShortfallBps()
        );

        _substitution = SubstitutionPlan({
            nonce: nonce,
            state: ScheduleState.Announced,
            outgoing: outgoing,
            incoming: incoming,
            outgoingWeightBps: outgoingComponent.weightBps,
            incomingWeightBps: incomingWeightBps,
            announcedAt: uint40(block.timestamp),
            executableAt: ScheduleMath.executableAt(delaySeconds),
            expiresAt: ScheduleMath.expiresAt(delaySeconds, ttlSeconds),
            outgoingBalanceSnapshot: IERC20(outgoing).balanceOf(address(this)),
            incomingRequiredValue: requiredValue,
            incomingReceived: 0,
            memoHash: memoHash
        });

        registry.markPendingRemoval(outgoing);
        registry.markPendingAdd(incoming, incomingWeightBps);

        emit SubstitutionAnnounced(
            nonce,
            outgoing,
            incoming,
            incomingWeightBps,
            _substitution.executableAt,
            _substitution.expiresAt,
            memoHash
        );
    }

    function receiveSubstitutionInventory(
        uint256 amount,
        address source
    ) external nonReentrant whenNotPaused onlyRole(REBALANCER_ROLE) {
        if (
            _substitution.state != ScheduleState.Announced &&
            _substitution.state != ScheduleState.Funded
        ) {
            revert ReverieErrors.NoActiveSchedule();
        }
        if (source == address(0)) revert ReverieErrors.ZeroAddress();
        if (amount == 0) revert ReverieErrors.InvalidAmount();

        address incoming = _substitution.incoming;
        incoming.safeTransferFrom(source, address(this), amount);
        ComponentConfig memory component = registry.getComponent(incoming);
        uint256 value = FixedPointMath.valueOf(
            amount,
            component.decimals,
            oracle.getPrice(incoming)
        );
        _substitution.incomingReceived += value;
        _substitution.state = ScheduleState.Funded;

        _validateCaps(_singleAsset(incoming));
        emit SubstitutionInventoryReceived(_substitution.nonce, incoming, source, amount, value);
    }

    function completeSubstitution() external whenNotPaused onlyRole(REBALANCER_ROLE) {
        if (
            _substitution.state != ScheduleState.Announced &&
            _substitution.state != ScheduleState.Funded
        ) {
            revert ReverieErrors.NoActiveSchedule();
        }
        ScheduleMath.requireExecutable(_substitution.executableAt, _substitution.expiresAt);

        ComponentConfig memory incomingComponent = registry.getComponent(_substitution.incoming);
        uint256 incomingValue = FixedPointMath.valueOf(
            IERC20(_substitution.incoming).balanceOf(address(this)),
            incomingComponent.decimals,
            oracle.getPrice(_substitution.incoming)
        );
        (, uint256 minimumValue) = ScheduleMath.substitutionRequirement(
            basketToken.totalSupply(),
            _substitution.incomingWeightBps,
            riskPolicy.maxSubstitutionShortfallBps()
        );
        if (incomingValue < minimumValue) {
            revert ReverieErrors.SubstitutionInventoryShortfall(
                _substitution.incoming,
                incomingValue,
                minimumValue
            );
        }

        registry.completeSubstitution(
            _substitution.outgoing,
            _substitution.incoming,
            _substitution.incomingWeightBps
        );

        _lastSubstitution = _substitution;
        _lastSubstitution.state = ScheduleState.Applied;
        emit SubstitutionCompleted(
            _substitution.nonce,
            _substitution.outgoing,
            _substitution.incoming
        );
        delete _substitution;
    }

    function cancelSubstitution() external onlyRole(REBALANCER_ROLE) {
        if (
            _substitution.state != ScheduleState.Announced &&
            _substitution.state != ScheduleState.Funded
        ) {
            revert ReverieErrors.NoActiveSchedule();
        }
        uint64 nonce = _substitution.nonce;
        address outgoing = _substitution.outgoing;
        address incoming = _substitution.incoming;
        registry.cancelPendingSubstitution(outgoing, incoming);
        _lastSubstitution = _substitution;
        _lastSubstitution.state = ScheduleState.Cancelled;
        delete _substitution;
        emit SubstitutionCancelled(nonce, outgoing, incoming);
    }

    function sweepRetiredAsset(
        address asset,
        address receiver,
        uint256 amount
    ) external nonReentrant onlyRole(GOVERNOR_ROLE) {
        if (receiver == address(0)) revert ReverieErrors.ZeroAddress();
        ComponentConfig memory component = registry.getComponent(asset);
        if (component.status != ComponentStatus.Retired)
            revert ReverieErrors.InvalidComponent(asset);
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (amount == type(uint256).max) amount = balance;
        if (amount > balance) revert ReverieErrors.InsufficientBalance(asset, balance, amount);
        asset.safeTransfer(receiver, amount);
        emit RetiredAssetSwept(asset, receiver, amount);
    }

    function grossBasketValue() public view returns (uint256) {
        return _portfolioValue(registry.allComponents());
    }

    function accountingBasketValue() public view returns (uint256) {
        return _portfolioValue(registry.backingComponents());
    }

    function backedSupply() public view returns (uint256) {
        uint256 supply = basketToken.totalSupply();
        if (supply == 0) return 0;
        uint256 value = accountingBasketValue();
        return FixedPointMath.min(supply, value);
    }

    function navPerShare() public view returns (uint256) {
        uint256 supply = basketToken.totalSupply();
        if (supply == 0) return WAD;
        return grossBasketValue().divWadDown(supply);
    }

    function accountingNavPerShare() public view returns (uint256) {
        uint256 supply = basketToken.totalSupply();
        if (supply == 0) return WAD;
        return accountingBasketValue().divWadDown(supply);
    }

    function navReport() public view returns (NavReport memory report) {
        uint256 supply = basketToken.totalSupply();
        uint256 grossValue = grossBasketValue();
        uint256 accountingValue = accountingBasketValue();
        uint256 supplyBasis = backedSupply();
        report = NavReport({
            totalSupply: supply,
            grossValue: grossValue,
            accountingValue: accountingValue,
            backedSupply: supplyBasis,
            navPerShare: supply == 0 ? WAD : grossValue.divWadDown(supply),
            accountingNavPerShare: supply == 0 ? WAD : accountingValue.divWadDown(supply),
            transitionWindow: _substitution.state == ScheduleState.Announced ||
                _substitution.state == ScheduleState.Funded
        });
    }

    function componentValue(address asset) public view returns (ComponentValue memory value) {
        ComponentConfig memory component = registry.getComponent(asset);
        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 price = oracle.getPrice(asset);
        value = ComponentValue({
            asset: asset,
            balance: balance,
            price: price,
            value: FixedPointMath.valueOf(balance, component.decimals, price),
            weightBps: component.weightBps,
            status: component.status
        });
    }

    function componentValues(
        address[] calldata assets
    ) external view returns (ComponentValue[] memory values) {
        values = new ComponentValue[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            values[i] = componentValue(assets[i]);
        }
    }

    function accountSnapshot(
        address account
    ) external view returns (AccountSnapshot memory snapshot) {
        uint256 shares = basketToken.balanceOf(account);
        uint256 supply = basketToken.totalSupply();
        address[] memory assets = registry.activeComponents();
        uint256[] memory balances = _balances(assets);
        AssetAmount[] memory claims;
        if (supply == 0 || shares == 0) {
            claims = new AssetAmount[](assets.length);
            for (uint256 i = 0; i < assets.length; ++i) {
                claims[i] = AssetAmount({asset: assets[i], amount: 0});
            }
        } else {
            claims = BasketMath.quoteProRata(assets, balances, shares, supply);
        }
        snapshot = AccountSnapshot({
            account: account,
            shares: shares,
            grossClaimValue: supply == 0 ? 0 : grossBasketValue().mulDiv(shares, supply),
            accountingClaimValue: supply == 0 ? 0 : accountingBasketValue().mulDiv(shares, supply),
            activeClaims: claims
        });
    }

    function currentWeightUpdate() external view returns (WeightUpdate memory) {
        return _weightUpdate;
    }

    function pendingWeightAssets()
        external
        view
        returns (address[] memory assets, uint16[] memory weights)
    {
        assets = new address[](_pendingWeightAssets.length);
        weights = new uint16[](_pendingWeightBps.length);
        for (uint256 i = 0; i < _pendingWeightAssets.length; ++i) {
            assets[i] = _pendingWeightAssets[i];
            weights[i] = _pendingWeightBps[i];
        }
    }

    function currentSubstitution() external view returns (SubstitutionPlan memory) {
        return _substitution;
    }

    function lastSubstitution() external view returns (SubstitutionPlan memory) {
        return _lastSubstitution;
    }

    function lastHarvest(address asset) external view returns (HarvestReport memory) {
        return _lastHarvest[asset];
    }

    function _inKindSupplyBasis() internal view returns (uint256) {
        uint256 supply = basketToken.totalSupply();
        if (supply == 0) revert ReverieErrors.SupplyUnavailable();
        if (
            _substitution.state == ScheduleState.Announced ||
            _substitution.state == ScheduleState.Funded
        ) {
            uint256 supported = backedSupply();
            if (supported == 0) revert ReverieErrors.SupplyUnavailable();
            return supported;
        }
        return supply;
    }

    function _portfolioValue(address[] memory assets) internal view returns (uint256 value) {
        for (uint256 i = 0; i < assets.length; ++i) {
            ComponentConfig memory component = registry.getComponent(assets[i]);
            uint256 balance = IERC20(assets[i]).balanceOf(address(this));
            uint256 price = oracle.getPrice(assets[i]);
            value += FixedPointMath.valueOf(balance, component.decimals, price);
        }
    }

    function _componentConfigs(
        address[] memory assets
    ) internal view returns (ComponentConfig[] memory configs) {
        configs = new ComponentConfig[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            configs[i] = registry.getComponent(assets[i]);
        }
    }

    function _prices(address[] memory assets) internal view returns (uint256[] memory prices) {
        prices = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            prices[i] = oracle.getPrice(assets[i]);
        }
    }

    function _balances(address[] memory assets) internal view returns (uint256[] memory balances) {
        balances = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            balances[i] = IERC20(assets[i]).balanceOf(address(this));
        }
    }

    function _validateCaps(address[] memory assets) internal view {
        for (uint256 i = 0; i < assets.length; ++i) {
            ComponentConfig memory component = registry.getComponent(assets[i]);
            BasketMath.enforceBalanceCap(component, IERC20(assets[i]).balanceOf(address(this)));
        }
    }

    function _singleAsset(address asset) internal pure returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = asset;
    }

    function _transferOutputs(address receiver, AssetAmount[] memory outputs) internal {
        for (uint256 i = 0; i < outputs.length; ++i) {
            AssetAmount memory output = outputs[i];
            if (output.amount != 0) output.asset.safeTransfer(receiver, output.amount);
        }
    }
}
