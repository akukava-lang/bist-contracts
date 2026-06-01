# BIST Smart Contract Security Review

**Project:** BusinessInfo Subscription Token (BIST) by BIA (Georgia)
**Contracts reviewed:** `BusinessInfoToken_v3_2.sol`, `BISTVesting_v2.sol`
**Live deployment (v3.1 / v1):** Polygon mainnet
- Token: [`0xd248C73250C8A53BbC17025a72dF4320610D7fe3`](https://polygonscan.com/address/0xd248C73250C8A53BbC17025a72dF4320610D7fe3)
- Vesting: [`0x1c7E15756BD3F011C0D9077d3C5fE8Ac47a12bB3`](https://polygonscan.com/address/0x1c7E15756BD3F011C0D9077d3C5fE8Ac47a12bB3)

**Scope:** Internal manual review and automated analysis (Remix Solidity Analyzers + Solhint).
**Status:** Preparatory — a professional third-party audit is the next step, for which this document is part of the application package.

---

## Overall verdict

Both contracts are well-structured and use battle-tested OpenZeppelin v5 base contracts. The review found **no critical or high-severity vulnerabilities.** All identified issues are either defense-in-depth hardening opportunities or deliberate design decisions to be confirmed by external audit. The corrected versions `v3.2` and `v2` apply the agreed hardening; the live `v3.1` and `v1` remain operational and are believed safe for current scale.

The most important security control — the unlimited-mint owner key — is operational rather than code-level. It is mitigated by holding the owner key on a hardware wallet.

---

## Findings — `BusinessInfoToken`

### M-1 — Missing per-entry discount cap in `setLoyaltyTiers` / `setVolumeTiers`
**Severity:** Medium (defense-in-depth)
**Status (v3.2):** Fixed

The admin functions `setLoyaltyTiers` and `setVolumeTiers` accepted arbitrary `discountsBps[]` values without validating each entry against `maxDiscountBps`. The final clamp in `calculateDiscount` still protects total discounts from exceeding the cap, so no exploitable bug exists today; however, allowing an arbitrarily high stored value violates least-surprise and could become exploitable if the calculation path is ever modified.

**Fix:** Each entry is validated against `maxDiscountBps` before being pushed to storage. Function reverts if any entry exceeds the cap.

### M-2 — `deactivateSubscription` has no reactivation path
**Severity:** Medium (operational)
**Status (v3.2):** Fixed

The owner can deactivate a subscription for compliance or refund reasons but had no on-chain way to undo the action if the deactivation was an error. This forced any restoration to go through a new redemption, costing the user additional tokens.

**Fix:** Added `reactivateSubscription(address wallet, uint256 tierId)`. Restores the `active` flag without modifying `expiryTime`; the original unlock window is preserved. Emits `SubscriptionReactivated`.

### L-1 — Loyalty credit asymmetry between single and batch redemption
**Severity:** Low (economic)
**Status (v3.2):** Fixed

`redeemTokens()` incremented `totalRedemptions` once per call. `batchRedeemTokens()` also incremented once, regardless of how many tiers were redeemed. As a result, a user redeeming three tiers via `redeemTokens` earned three loyalty credits, while the same user redeeming three tiers via `batchRedeemTokens` earned only one — an inconsistency that rewards splitting transactions and incurring more gas.

**Fix:** `batchRedeemTokens` now increments `totalRedemptions[msg.sender]` once per tier, matching the single-redemption behaviour.

### L-2 — Volume discount is per-tier, not aggregated across batch
**Severity:** Low (design decision)
**Status (v3.2):** Retained as designed

Within `batchRedeemTokens`, the volume discount is computed independently for each tier rather than against the batch total. The briefing flagged this for confirmation. The retained behaviour is intentional: it lets a user who buys several tiers each individually meet a volume threshold receive volume discounts on each, rather than receiving a single discount on the sum. External auditor is asked to confirm this is acceptable for the intended economics.

### I-2 — No pause / circuit breaker
**Severity:** Informational
**Status (v3.2):** Fixed

The token contract had no way to halt minting and redemption in the event of a discovered bug, an off-chain incident, or a coordinated emergency.

**Fix:** Added `Pausable` from OpenZeppelin. `whenNotPaused` is applied to `mintToClient`, `batchMintToClients`, `redeemTokens`, and `batchRedeemTokens`. Transfers remain enabled when paused so that token holders are never trapped. Owner controls `pause()` / `unpause()`.

### I-3 — Unlimited owner mint
**Severity:** Informational (governance)
**Status (v3.2):** Retained as the project's central trust assumption

The owner can mint arbitrary amounts of BIST. This is intentional: the project's economic model relies on minting against verified off-chain payment, and the supply policy is operational rather than encoded. Hard supply caps and minting-by-public-sale mechanisms can be introduced in a future major version if the project's governance model evolves.

**Mitigation (operational):** The owner key is held on a hardware wallet, not in browser-extension custody. This makes the mint power resistant to remote compromise of the operator's machine.

External auditor is asked to confirm this trust assumption is clearly disclosed to token holders.

---

## Findings — `BISTVesting`

### M-3 — `revokeGrant` could claw back grants post-unlock
**Severity:** Medium (trust)
**Status (v2):** Fixed

In v1, the owner could revoke a grant at any time, including after the unlock period had elapsed — even though the recipient was, by that point, the rightful claimant under the contract's stated intent ("trustless on-chain"). The behaviour contradicted the lock's claim to be a real, time-bound guarantee.

**Fix:** Each grant now carries a per-grant `guaranteeAfterUnlock` boolean, set at deposit time. When `true`, the contract refuses to honour `revokeGrant` once `block.timestamp >= unlockTime`. This makes the lock genuinely binding for grants that opt in (suitable for institutional or trust-critical distributions), while still allowing the owner to revoke unclaimed promotional grants pre-unlock if needed.

Per-grant rather than contract-wide so that the guarantee is encoded in the grant itself; the owner cannot retroactively flip a global flag to recover revocation power on already-deposited guaranteed grants.

### L-4 — `depositVesting` and `batchDepositVesting` not `nonReentrant`
**Severity:** Low (defense-in-depth)
**Status (v2):** Fixed

These functions call `IERC1155.safeTransferFrom`, which can invoke `onERC1155Received` on the `from` address. In practice the `from` is the project owner (a hardware-wallet EOA, no callback), so reentrancy is not currently exploitable. Confirmed by Remix Solidity Analyzer's Check-Effects-Interaction finding on these exact functions, which agrees with the manual finding.

**Fix:** Both functions are now `nonReentrant`. `revokeGrant` is also `nonReentrant` for consistency.

### L-5 — Unbounded loops in `claimAll` and `claimableAmount`
**Severity:** Low (operational)
**Status (v2):** Retained as designed

If a single recipient accumulates a very large number of grants, calling `claimAll` could exceed the block gas limit and fail. The per-grant `claim(uint256 grantId)` function is the safety valve and remains usable regardless of total grant count. This is documented in the contract's NatSpec.

External auditor is asked to confirm the per-grant safety valve is sufficient mitigation for the expected scale.

---

## Automated analysis

**Slither:** Local install failed due to Python 3.14 incompatibility (`solc-select` failed silently) plus a blocked compiler download host in the build environment. Not attempted further.

**Remix Solidity Analyzer + Solhint** (run on `BISTVesting` flattened source):
- 159 Remix findings, 25 Solhint findings — almost all noise from inlined OpenZeppelin library code in the flattened file.
- The only findings on project code were Check-Effects-Interaction warnings on `depositVesting` and `batchDepositVesting`, **confirming the manual L-4 finding.** No new issues surfaced.

**Token contract:** not yet run through automated analyser; expected to surface the same library noise plus a confirmation of the items already addressed in v3.2.

---

## Recommended next steps

1. **Professional third-party audit** of `v3.2` and `v2` before significant value flows through the system. Application to the Arbitrum Audit Subsidy Program is the active path. Approved auditor firms on that program include OpenZeppelin, Trail of Bits, Nethermind Security, Certora, and others.
2. **Hardware-wallet migration** of the owner key (operational, not code-level; in progress).
3. **External classification of BIST under Georgian law** (utility token vs. virtual asset under VASP rules vs. stablecoin under the March 2026 NBG order) by Georgian crypto/fintech counsel, before significant distribution.
4. **Confirmation from external audit** of the two design decisions retained as-is: L-2 (per-tier volume discount in batch) and L-5 (unbounded loop with per-grant safety valve).

---

*This document is an internal review prepared as part of the audit-application package. It is not a substitute for, and does not represent, a professional third-party security audit.*
