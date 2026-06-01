// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  BusinessInfoToken v3.2 — Universal Utility Token Contract
//  Blockchain  : Polygon (MATIC) / Arbitrum (target)
//  Standard    : ERC-1155 (single universal token ID = 0)
//
//  Changes from v3.1:
//  - [M-1] Per-entry discount cap on setLoyaltyTiers / setVolumeTiers
//          (defense-in-depth; final clamp at calculateDiscount still holds)
//  - [M-2] Added reactivateSubscription to pair with deactivateSubscription
//  - [L-1] Loyalty credit symmetry between single and batch redemption
//          (batchRedeemTokens now increments totalRedemptions per tier)
//  - [I-2] Added Pausable circuit breaker on mint/redeem entry points
//
//  Deliberately retained from v3.1:
//  - [L-2] Volume discount is per-redemption (not aggregated across batch)
//          — design decision; lets large batches still receive volume
//          discount on each tier individually
//  - [I-3] Owner can mint any amount, no supply cap
//          — central trust assumption of the project; mitigated
//          operationally by holding the owner key on a hardware wallet
//
//  Features (unchanged from v3.1):
//  - Universal BIST token, spendable across 21 service tiers
//  - Non-expiring tokens, redeem-to-activate subscription model
//  - 4-layer discount system: seasonal / loyalty / volume / coupon
//  - Configurable best-of OR combined stacking, max 30% cap (raisable to 50%)
//  - Freely transferable (tradeable on any marketplace)
//  - 1 BIST = 0.1 GEL face value (1 GEL = 10 BIST)
// ============================================================

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract BusinessInfoToken is ERC1155, Ownable, ERC1155Supply, ReentrancyGuard, Pausable {

    string public name   = "BusinessInfo Subscription Token";
    string public symbol = "BIST";

    // Universal token ID — all tokens are BIST (ID = 0)
    uint256 public constant BIST = 0;

    // ─────────────────────────────────────────────
    //  SERVICE TIER DEFINITION
    // ─────────────────────────────────────────────

    struct ServiceTier {
        string  serviceName;
        uint256 durationDays;
        bool    downloadEnabled;
        uint8   maxUsers;
        bool    outsideIP;
        uint256 baseTokenCost;
        bool    exists;
    }

    mapping(uint256 => ServiceTier) public serviceTiers;
    uint256 public constant TOTAL_TIERS = 21;

    // ─────────────────────────────────────────────
    //  SUBSCRIPTION TRACKING
    // ─────────────────────────────────────────────

    struct Subscription {
        uint256 tierId;
        uint256 startTime;
        uint256 expiryTime;
        bool    active;
    }

    mapping(address => mapping(uint256 => Subscription)) public subscriptions;
    mapping(address => uint256) public totalRedemptions;

    // ─────────────────────────────────────────────
    //  DISCOUNT STRUCTURES
    // ─────────────────────────────────────────────

    struct SeasonalDiscount {
        string  name;
        uint256 discountBps;
        uint256 startTime;
        uint256 endTime;
        bool    active;
        uint256 tierId; // 0 = all tiers
    }

    SeasonalDiscount[] public seasonalDiscounts;

    struct LoyaltyTier {
        uint256 minRedemptions;
        uint256 discountBps;
    }

    LoyaltyTier[] public loyaltyTiers;

    struct VolumeTier {
        uint256 minTokens;
        uint256 discountBps;
    }

    VolumeTier[] public volumeTiers;

    struct CouponDiscount {
        uint256 discountBps;
        uint256 expiryTime;
        bool    active;
    }

    mapping(address => CouponDiscount) public couponDiscounts;

    bool public stackDiscounts = false;
    uint256 public maxDiscountBps = 3000; // 30% default
    uint256 public constant ABSOLUTE_MAX_DISCOUNT_BPS = 5000; // 50% hard ceiling

    // ─────────────────────────────────────────────
    //  EVENTS
    // ─────────────────────────────────────────────

    event TokensMinted(address indexed to, uint256 amount);

    event TokensRedeemed(
        address indexed redeemer,
        uint256 indexed tierId,
        uint256 tokensBurned,
        uint256 discountBps,
        uint256 subscriptionExpiry
    );

    event SubscriptionRenewed(address indexed subscriber, uint256 indexed tierId, uint256 newExpiry);
    event SubscriptionDeactivated(address indexed subscriber, uint256 indexed tierId);
    event SubscriptionReactivated(address indexed subscriber, uint256 indexed tierId, uint256 expiryTime);

    event SeasonalDiscountCreated(uint256 index, string discountName, uint256 discountBps);
    event CouponGranted(address indexed wallet, uint256 discountBps);
    event StackModeChanged(bool stackDiscounts);
    event MaxDiscountChanged(uint256 newMaxBps);
    event LoyaltyTiersUpdated(uint256 count);
    event VolumeTiersUpdated(uint256 count);

    // ─────────────────────────────────────────────
    //  CONSTRUCTOR
    // ─────────────────────────────────────────────

    constructor(address initialOwner)
        ERC1155("https://your-metadata-url.com/api/token/0.json")
        Ownable(initialOwner)
    {
        _initializeServiceTiers();
        _initializeDefaultDiscountTiers();
    }

    // ─────────────────────────────────────────────
    //  INITIALIZE 21 SERVICE TIERS
    // ─────────────────────────────────────────────

    function _initializeServiceTiers() internal {

        // ── GROUP A: Annual WITH Download ──────────────────────────────

        serviceTiers[1] = ServiceTier("Annual Subscription + Download, 1 User", 365, true, 1, false, 120000, true);
        serviceTiers[2] = ServiceTier("Annual Subscription + Download, 2 Users", 365, true, 2, false, 150000, true);
        serviceTiers[3] = ServiceTier("Annual Subscription + Download, 3 Users", 365, true, 3, false, 180000, true);
        serviceTiers[4] = ServiceTier("Annual Subscription + Download, 3+ Users", 365, true, 0, false, 210000, true);

        // ── GROUP B: Annual WITHOUT Download ───────────────────────────

        serviceTiers[5]  = ServiceTier("Annual Subscription, No Download, 1 User",                    365, false, 1, false, 33000, true);
        serviceTiers[6]  = ServiceTier("Annual Subscription, No Download, 2 Users",                   365, false, 2, false, 34500, true);
        serviceTiers[7]  = ServiceTier("Annual Subscription, No Download, 3 Users",                   365, false, 3, false, 36000, true);
        serviceTiers[8]  = ServiceTier("Annual Subscription, No Download, 3+ Users",                  365, false, 0, false, 37500, true);
        serviceTiers[9]  = ServiceTier("Annual Subscription, No Download, 1 User + Outside IP",       365, false, 1, true,  39000, true);
        serviceTiers[10] = ServiceTier("Annual Subscription, No Download, 2 Users + Outside IP",      365, false, 2, true,  45000, true);
        serviceTiers[11] = ServiceTier("Annual Subscription, No Download, 3 Users + Outside IP",      365, false, 3, true,  54000, true);

        // ── GROUP C: Semiannual WITHOUT Download ───────────────────────

        serviceTiers[12] = ServiceTier("Semiannual Subscription, No Download, 1 User",                180, false, 1, false, 18000, true);
        serviceTiers[13] = ServiceTier("Semiannual Subscription, No Download, 2 Users",               180, false, 2, false, 21000, true);
        serviceTiers[14] = ServiceTier("Semiannual Subscription, No Download, 3 Users",               180, false, 3, false, 24000, true);
        serviceTiers[15] = ServiceTier("Semiannual Subscription, No Download, 3+ Users",              180, false, 0, false, 27000, true);
        serviceTiers[16] = ServiceTier("Semiannual Subscription, No Download, 1 User + Outside IP",   180, false, 1, true,  24000, true);
        serviceTiers[17] = ServiceTier("Semiannual Subscription, No Download, 2 Users + Outside IP",  180, false, 2, true,  27000, true);
        serviceTiers[18] = ServiceTier("Semiannual Subscription, No Download, 3 Users + Outside IP",  180, false, 3, true,  30000, true);

        // ── GROUP D: 3-Month WITHOUT Download ──────────────────────────

        serviceTiers[19] = ServiceTier("3-Month Subscription, No Download, 1 User",                    90, false, 1, false, 12000, true);
        serviceTiers[20] = ServiceTier("3-Month Subscription, No Download, 2 Users",                   90, false, 2, false, 13500, true);
        serviceTiers[21] = ServiceTier("3-Month Subscription, No Download, 3 Users",                   90, false, 3, false, 15000, true);
    }

    function _initializeDefaultDiscountTiers() internal {
        loyaltyTiers.push(LoyaltyTier(2,  500));
        loyaltyTiers.push(LoyaltyTier(5,  1000));
        loyaltyTiers.push(LoyaltyTier(10, 1500));

        volumeTiers.push(VolumeTier(50000,  500));
        volumeTiers.push(VolumeTier(100000, 1000));
        volumeTiers.push(VolumeTier(200000, 1500));
    }

    // ─────────────────────────────────────────────
    //  MINTING
    // ─────────────────────────────────────────────

    function mintToClient(address to, uint256 amount)
        external
        onlyOwner
        whenNotPaused // [I-2]
    {
        require(to != address(0), "Cannot mint to zero address");
        require(amount > 0, "Amount must be greater than zero");
        _mint(to, BIST, amount, "");
        emit TokensMinted(to, amount);
    }

    function batchMintToClients(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyOwner whenNotPaused { // [I-2]
        require(recipients.length == amounts.length, "Length mismatch");
        for (uint256 i = 0; i < recipients.length; i++) {
            require(recipients[i] != address(0), "Cannot mint to zero address");
            require(amounts[i] > 0, "Amount must be greater than zero");
            _mint(recipients[i], BIST, amounts[i], "");
            emit TokensMinted(recipients[i], amounts[i]);
        }
    }

    // ─────────────────────────────────────────────
    //  DISCOUNT CALCULATION ENGINE
    // ─────────────────────────────────────────────

    function calculateDiscount(
        address wallet,
        uint256 tierId,
        uint256 baseTokenCost
    ) public view returns (uint256 discountBps) {
        uint256 seasonal = _getSeasonalDiscount(tierId);
        uint256 loyalty  = _getLoyaltyDiscount(wallet);
        uint256 volume   = _getVolumeDiscount(baseTokenCost);
        uint256 coupon   = _getCouponDiscount(wallet);

        if (stackDiscounts) {
            discountBps = seasonal + loyalty + volume + coupon;
        } else {
            discountBps = seasonal;
            if (loyalty > discountBps) discountBps = loyalty;
            if (volume  > discountBps) discountBps = volume;
            if (coupon  > discountBps) discountBps = coupon;
        }

        if (discountBps > maxDiscountBps) {
            discountBps = maxDiscountBps;
        }
    }

    function calculateFinalCost(
        address wallet,
        uint256 tierId
    ) public view returns (uint256 finalCost, uint256 discountBps) {
        require(serviceTiers[tierId].exists, "Invalid service tier");
        uint256 base = serviceTiers[tierId].baseTokenCost;
        discountBps  = calculateDiscount(wallet, tierId, base);
        uint256 discountAmount = (base * discountBps) / 10000;
        finalCost    = base - discountAmount;
    }

    function _getSeasonalDiscount(uint256 tierId) internal view returns (uint256 best) {
        for (uint256 i = 0; i < seasonalDiscounts.length; i++) {
            SeasonalDiscount memory sd = seasonalDiscounts[i];
            if (
                sd.active &&
                block.timestamp >= sd.startTime &&
                block.timestamp <= sd.endTime &&
                (sd.tierId == 0 || sd.tierId == tierId)
            ) {
                if (sd.discountBps > best) best = sd.discountBps;
            }
        }
    }

    function _getLoyaltyDiscount(address wallet) internal view returns (uint256 best) {
        uint256 redemptions = totalRedemptions[wallet];
        for (uint256 i = 0; i < loyaltyTiers.length; i++) {
            if (
                redemptions >= loyaltyTiers[i].minRedemptions &&
                loyaltyTiers[i].discountBps > best
            ) {
                best = loyaltyTiers[i].discountBps;
            }
        }
    }

    function _getVolumeDiscount(uint256 baseTokenCost) internal view returns (uint256 best) {
        for (uint256 i = 0; i < volumeTiers.length; i++) {
            if (
                baseTokenCost >= volumeTiers[i].minTokens &&
                volumeTiers[i].discountBps > best
            ) {
                best = volumeTiers[i].discountBps;
            }
        }
    }

    function _getCouponDiscount(address wallet) internal view returns (uint256) {
        CouponDiscount memory cd = couponDiscounts[wallet];
        if (cd.active && (cd.expiryTime == 0 || cd.expiryTime > block.timestamp)) {
            return cd.discountBps;
        }
        return 0;
    }

    // ─────────────────────────────────────────────
    //  REDEMPTION
    // ─────────────────────────────────────────────

    function redeemTokens(uint256 tierId)
        external
        nonReentrant
        whenNotPaused // [I-2]
    {
        require(tierId >= 1 && tierId <= TOTAL_TIERS, "Tier ID out of range (1-21)");
        require(serviceTiers[tierId].exists, "Invalid service tier");

        (uint256 finalCost, uint256 discountBps) = calculateFinalCost(msg.sender, tierId);

        require(
            balanceOf(msg.sender, BIST) >= finalCost,
            "Insufficient BIST tokens"
        );

        _burn(msg.sender, BIST, finalCost);

        uint256 durationSeconds = serviceTiers[tierId].durationDays * 1 days;
        uint256 newExpiry;

        Subscription storage sub = subscriptions[msg.sender][tierId];

        if (sub.active && sub.expiryTime > block.timestamp) {
            sub.expiryTime += durationSeconds;
            newExpiry = sub.expiryTime;
            emit SubscriptionRenewed(msg.sender, tierId, newExpiry);
        } else {
            newExpiry = block.timestamp + durationSeconds;
            subscriptions[msg.sender][tierId] = Subscription({
                tierId:     tierId,
                startTime:  block.timestamp,
                expiryTime: newExpiry,
                active:     true
            });
        }

        totalRedemptions[msg.sender]++;
        emit TokensRedeemed(msg.sender, tierId, finalCost, discountBps, newExpiry);
    }

    function batchRedeemTokens(uint256[] calldata tierIds)
        external
        nonReentrant
        whenNotPaused // [I-2]
    {
        uint256 totalCost = 0;

        // First pass: validate + calculate total cost
        for (uint256 i = 0; i < tierIds.length; i++) {
            require(tierIds[i] >= 1 && tierIds[i] <= TOTAL_TIERS, "Tier ID out of range (1-21)");
            require(serviceTiers[tierIds[i]].exists, "Invalid service tier");
            (uint256 cost, ) = calculateFinalCost(msg.sender, tierIds[i]);
            totalCost += cost;
        }

        require(
            balanceOf(msg.sender, BIST) >= totalCost,
            "Insufficient BIST tokens for batch"
        );

        // Second pass: burn and activate, incrementing redemptions per tier
        for (uint256 i = 0; i < tierIds.length; i++) {
            uint256 tierId = tierIds[i];
            (uint256 finalCost, uint256 discountBps) = calculateFinalCost(msg.sender, tierId);

            _burn(msg.sender, BIST, finalCost);

            uint256 durationSeconds = serviceTiers[tierId].durationDays * 1 days;
            uint256 newExpiry;

            Subscription storage sub = subscriptions[msg.sender][tierId];

            if (sub.active && sub.expiryTime > block.timestamp) {
                sub.expiryTime += durationSeconds;
                newExpiry = sub.expiryTime;
                emit SubscriptionRenewed(msg.sender, tierId, newExpiry);
            } else {
                newExpiry = block.timestamp + durationSeconds;
                subscriptions[msg.sender][tierId] = Subscription({
                    tierId:     tierId,
                    startTime:  block.timestamp,
                    expiryTime: newExpiry,
                    active:     true
                });
            }

            // [L-1] Increment per-tier so batch and single redemption are symmetric
            totalRedemptions[msg.sender]++;

            emit TokensRedeemed(msg.sender, tierId, finalCost, discountBps, newExpiry);
        }
    }

    // ─────────────────────────────────────────────
    //  ACCESS VERIFICATION
    // ─────────────────────────────────────────────

    function hasActiveSubscription(address wallet, uint256 tierId)
        external view returns (bool)
    {
        Subscription memory sub = subscriptions[wallet][tierId];
        return sub.active && sub.expiryTime > block.timestamp;
    }

    function getSubscriptionExpiry(address wallet, uint256 tierId)
        external view returns (uint256)
    {
        Subscription memory sub = subscriptions[wallet][tierId];
        if (sub.active && sub.expiryTime > block.timestamp) {
            return sub.expiryTime;
        }
        return 0;
    }

    function getSubscription(address wallet, uint256 tierId)
        external view returns (Subscription memory)
    {
        return subscriptions[wallet][tierId];
    }

    function getServiceTier(uint256 tierId)
        external view returns (ServiceTier memory)
    {
        require(serviceTiers[tierId].exists, "Invalid service tier");
        return serviceTiers[tierId];
    }

    // ─────────────────────────────────────────────
    //  ADMIN — DISCOUNT MANAGEMENT
    // ─────────────────────────────────────────────

    function createSeasonalDiscount(
        string calldata discountName,
        uint256 discountBps,
        uint256 startTime,
        uint256 endTime,
        uint256 tierId
    ) external onlyOwner {
        require(discountBps <= maxDiscountBps, "Exceeds max discount");
        require(endTime > startTime, "Invalid time range");

        seasonalDiscounts.push(SeasonalDiscount({
            name:        discountName,
            discountBps: discountBps,
            startTime:   startTime,
            endTime:     endTime,
            active:      true,
            tierId:      tierId
        }));

        emit SeasonalDiscountCreated(seasonalDiscounts.length - 1, discountName, discountBps);
    }

    function deactivateSeasonalDiscount(uint256 index) external onlyOwner {
        require(index < seasonalDiscounts.length, "Invalid index");
        seasonalDiscounts[index].active = false;
    }

    function grantCouponDiscount(
        address wallet,
        uint256 discountBps,
        uint256 expiryTime
    ) external onlyOwner {
        require(discountBps <= maxDiscountBps, "Exceeds max discount");
        couponDiscounts[wallet] = CouponDiscount({
            discountBps: discountBps,
            expiryTime:  expiryTime,
            active:      true
        });
        emit CouponGranted(wallet, discountBps);
    }

    function revokeCouponDiscount(address wallet) external onlyOwner {
        couponDiscounts[wallet].active = false;
    }

    /**
     * @dev Update loyalty discount thresholds. Replaces all existing loyalty tiers.
     * [M-1] Each entry validated against maxDiscountBps before storage.
     */
    function setLoyaltyTiers(
        uint256[] calldata minRedemptions,
        uint256[] calldata discountsBps
    ) external onlyOwner {
        require(minRedemptions.length == discountsBps.length, "Length mismatch");
        // [M-1] Defense-in-depth: cap each entry individually
        for (uint256 i = 0; i < discountsBps.length; i++) {
            require(discountsBps[i] <= maxDiscountBps, "Per-entry discount exceeds max");
        }
        delete loyaltyTiers;
        for (uint256 i = 0; i < minRedemptions.length; i++) {
            loyaltyTiers.push(LoyaltyTier({
                minRedemptions: minRedemptions[i],
                discountBps:    discountsBps[i]
            }));
        }
        emit LoyaltyTiersUpdated(minRedemptions.length);
    }

    /**
     * @dev Update volume discount thresholds. Replaces all existing volume tiers.
     * [M-1] Each entry validated against maxDiscountBps before storage.
     */
    function setVolumeTiers(
        uint256[] calldata minTokens,
        uint256[] calldata discountsBps
    ) external onlyOwner {
        require(minTokens.length == discountsBps.length, "Length mismatch");
        // [M-1] Defense-in-depth: cap each entry individually
        for (uint256 i = 0; i < discountsBps.length; i++) {
            require(discountsBps[i] <= maxDiscountBps, "Per-entry discount exceeds max");
        }
        delete volumeTiers;
        for (uint256 i = 0; i < minTokens.length; i++) {
            volumeTiers.push(VolumeTier({
                minTokens:   minTokens[i],
                discountBps: discountsBps[i]
            }));
        }
        emit VolumeTiersUpdated(minTokens.length);
    }

    function setStackDiscounts(bool _stack) external onlyOwner {
        stackDiscounts = _stack;
        emit StackModeChanged(_stack);
    }

    function setMaxDiscount(uint256 _maxBps) external onlyOwner {
        require(_maxBps <= ABSOLUTE_MAX_DISCOUNT_BPS, "Cannot exceed 50% max discount");
        maxDiscountBps = _maxBps;
        emit MaxDiscountChanged(_maxBps);
    }

    function updateServiceTierCost(
        uint256 tierId,
        uint256 newBaseTokenCost
    ) external onlyOwner {
        require(serviceTiers[tierId].exists, "Invalid service tier");
        serviceTiers[tierId].baseTokenCost = newBaseTokenCost;
    }

    /**
     * @dev Deactivate a subscription (compliance / refund case).
     */
    function deactivateSubscription(
        address wallet,
        uint256 tierId
    ) external onlyOwner {
        subscriptions[wallet][tierId].active = false;
        emit SubscriptionDeactivated(wallet, tierId);
    }

    /**
     * @dev [M-2] Reactivate a previously deactivated subscription.
     *      Only restores the `active` flag; the original expiryTime is unchanged.
     *      Will only have effect if expiryTime is still in the future.
     */
    function reactivateSubscription(
        address wallet,
        uint256 tierId
    ) external onlyOwner {
        Subscription storage sub = subscriptions[wallet][tierId];
        require(sub.expiryTime > 0, "No subscription on record");
        sub.active = true;
        emit SubscriptionReactivated(wallet, tierId, sub.expiryTime);
    }

    /**
     * @dev [I-2] Pause/unpause the contract in case of incident.
     *      Blocks minting and redemption; transfers remain enabled
     *      (holders are never trapped by a paused contract).
     */
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setURI(string memory newuri) external onlyOwner {
        _setURI(newuri);
    }

    // ─────────────────────────────────────────────
    //  REQUIRED OVERRIDES
    // ─────────────────────────────────────────────

    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override(ERC1155, ERC1155Supply) {
        super._update(from, to, ids, values);
    }
}
