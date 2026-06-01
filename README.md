# BIST — BusinessInfo Subscription Token

Smart contracts for the **BIST tokenization project** by **BIA** (Georgia).

BIST is an ERC-1155 subscription/loyalty token that lets businesses, agencies, and individuals redeem tokens for BIA's services. The token is currently deployed on Polygon mainnet, with significantly modified versions (`v3.2` for the token, `v2` for the vesting contract) prepared as the next deployment.

This repository contains the production contracts, the internal security review, and supporting documentation. It is provided for transparency and to support a third-party smart contract security audit.

---

## Project at a glance

- **Issuer:** BIA — an established company operating in Georgia, with an existing customer base across businesses, agencies, and institutional clients.
- **Token:** BusinessInfo Subscription Token (BIST), ERC-1155, single universal token ID = 0.
- **Pricing:** 1 GEL = 10 BIST. Tokens are redeemable for BIA services across 21 service tiers.
- **Product site:** https://token.bia.ge
- **Current deployment:** Polygon mainnet (Chain ID 137)
  - Token (`BusinessInfoToken` v3.1): [`0xd248C73250C8A53BbC17025a72dF4320610D7fe3`](https://polygonscan.com/address/0xd248C73250C8A53BbC17025a72dF4320610D7fe3)
  - Vesting (`BISTVesting`): [`0x1c7E15756BD3F011C0D9077d3C5fE8Ac47a12bB3`](https://polygonscan.com/address/0x1c7E15756BD3F011C0D9077d3C5fE8Ac47a12bB3)
- **Next deployment:** Significantly modified `v3.2` token and `v2` vesting contracts. See "Modifications" below.

---

## Contracts

### `contracts/BusinessInfoToken_v3_2.sol`

ERC-1155 subscription/loyalty token. Key features:

- **21 service tiers**, each priced in BIST.
- **4-layer discount system** — seasonal, loyalty, volume, coupon — applied as best-of by default, with a 30% maximum discount cap (raisable to 50%).
- **Owner-controlled minting** — no supply cap. This is a documented trust assumption (see I-3 in the security review), mitigated operationally by holding the owner key on a hardware wallet.
- **Subscription lifecycle** — activation, renewal, deactivation, reactivation.
- **Pausable circuit breaker** — added in v3.2; blocks mint and redeem entry points, transfers remain enabled.
- **ReentrancyGuard** on all redemption flows.
- **Base contracts (OpenZeppelin v5):** `ERC1155`, `ERC1155Supply`, `Ownable`, `ReentrancyGuard`, `Pausable`.

### `contracts/BISTVesting_v2.sol`

Token vesting / grant contract used for the BIST distribution program. Key features:

- **Per-grant configurable lock**, default 90 days.
- **Per-grant `guaranteeAfterUnlock` flag** — when set, blocks revocation of grants after unlock. Makes the lock genuinely binding for trust-critical grants while preserving revocability for promotional ones.
- **Single and batch deposits** — both `nonReentrant` in v2.
- **Per-grant `claim()` and `claimAll()`** — per-grant claim is the safety valve against unbounded loops at very large grant counts.
- **Base contracts (OpenZeppelin v5):** `Ownable`, `ReentrancyGuard`, `ERC1155Holder`.

---

## Modifications in `v3.2` / `v2` (vs. live `v3.1` / `v1`)

These versions address findings from the internal security review (see `security/BIST_Security_Review.md`). They are **significantly modified code** — appropriate for fresh third-party audit, and qualifying as significantly modified code under audit-program definitions.

**Token (`BusinessInfoToken_v3_2.sol`):**

- **M-1 fixed** — added per-entry discount cap validation in `setLoyaltyTiers` / `setVolumeTiers` (defense-in-depth; the calculation-side clamp also remains).
- **M-2 fixed** — added `reactivateSubscription` to pair with the existing `deactivateSubscription`.
- **L-1 fixed** — loyalty credit symmetry between single and batch redemption. `batchRedeemTokens` now increments `totalRedemptions` once per tier.
- **L-2 retained** — volume discount remains per-tier in a batch (not aggregated across the batch). Documented design decision.
- **I-2 fixed** — added `Pausable` circuit breaker on mint and redeem entry points.
- **I-3 retained** — unlimited owner mint is the documented trust assumption of the project, mitigated operationally.

**Vesting (`BISTVesting_v2.sol`):**

- **M-3 fixed** — per-grant `guaranteeAfterUnlock` flag. When `true`, the owner cannot revoke once unlock has occurred.
- **L-4 fixed** — `depositVesting`, `batchDepositVesting`, and `revokeGrant` are now `nonReentrant`.
- **L-5 retained** — unbounded loops in `claimAll` / `claimableAmount` retained; per-grant `claim()` remains the safety valve. Documented.

Full findings, severity, and rationale: see `security/BIST_Security_Review.md`.

---

## Repository structure

```
bist-contracts/
├── README.md
├── LICENSE                          (MIT)
├── contracts/
│   ├── BusinessInfoToken_v3_2.sol
│   └── BISTVesting_v2.sol
└── security/
    └── BIST_Security_Review.md
```

---

## Technical stack

- **Solidity:** `^0.8.20` (compiled on `v0.8.25`)
- **OpenZeppelin Contracts:** `v5.x`
- **Standards:** ERC-1155 (token), Ownable, ReentrancyGuard, Pausable
- **Current network:** Polygon mainnet (Chain ID 137)
- **Target network for next deployment:** under evaluation — Arbitrum One is under active consideration.

---

## Audit status

- **Internal manual review:** complete (see `security/BIST_Security_Review.md`).
- **Automated analysis:** Remix Solidity Analyzers + Solhint run on `BISTVesting`. The only project-code findings (Check-Effects-Interaction on deposit functions) confirm the manual L-4 finding, already addressed in v2.
- **Professional third-party audit:** not yet performed. **This is the purpose of the present audit engagement.**

---

## About BIA

BIA is an established business operating in Georgia with a real customer base across businesses, agencies, and institutional clients. BIST is BIA's tokenization layer — a way for individuals and organisations to acquire and redeem tokens for BIA's services on-chain.

Project inquiries: see https://token.bia.ge.

---

## License

[MIT](LICENSE)
