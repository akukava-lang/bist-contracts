// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  BISTVesting v2 — Token Vesting Contract for BIST
//  Blockchain  : Polygon (MATIC) / Arbitrum (target)
//
//  Purpose: Lock BIST tokens for recipients for a fixed period
//          (default 90 days). Optionally guarantee that the lock
//          is honoured — i.e. the owner cannot revoke after unlock.
//
//  Changes from v1:
//  - [M-3] Per-grant `guaranteeAfterUnlock` flag set at deposit time.
//          When true, the grant cannot be revoked once unlocked.
//          This makes the lock genuinely trustless for grants that
//          opt in, while still allowing revocable promotional grants.
//  - [L-4] depositVesting and batchDepositVesting are now nonReentrant.
//          Defense-in-depth: the ERC-1155 safeTransferFrom called from
//          these functions can invoke onERC1155Received on the caller
//          (owner), which is normally a trusted EOA but the guard
//          eliminates the entire class of risk.
//
//  Deliberately retained from v1:
//  - [L-5] Unbounded loops in claimAll() and claimableAmount()
//          — per-grant claim() is the safety valve. If a recipient ever
//          accumulates so many grants that claimAll exceeds the block
//          gas limit, they can still claim each grant individually.
//
//  Flow:
//  1. Owner calls depositVesting(recipient, amount, durationDays, guaranteeAfterUnlock)
//  2. Contract holds tokens until lock expires
//  3. Recipient calls claim(grantId) — or claimAll() — to receive tokens
//  4. Owner may revoke an unclaimed grant ONLY if:
//        - the grant has not been claimed, AND
//        - either guaranteeAfterUnlock is false, OR unlock has not occurred yet
// ============================================================

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

contract BISTVesting is Ownable, ReentrancyGuard, ERC1155Holder {

    address public bistTokenAddress;
    uint256 public constant BIST_ID = 0;

    // ─────────────────────────────────────────────
    //  VESTING SCHEDULE
    // ─────────────────────────────────────────────

    struct VestingGrant {
        address recipient;
        uint256 amount;
        uint256 startTime;
        uint256 unlockTime;
        bool    claimed;
        bool    revoked;
        bool    guaranteeAfterUnlock; // [M-3] If true, blocks post-unlock revoke
    }

    VestingGrant[] public grants;
    mapping(address => uint256[]) public recipientGrants;

    // ─────────────────────────────────────────────
    //  EVENTS
    // ─────────────────────────────────────────────

    event GrantCreated(
        uint256 indexed grantId,
        address indexed recipient,
        uint256 amount,
        uint256 unlockTime,
        bool guaranteeAfterUnlock
    );

    event GrantClaimed(
        uint256 indexed grantId,
        address indexed recipient,
        uint256 amount
    );

    event GrantRevoked(
        uint256 indexed grantId,
        address indexed recipient,
        uint256 amount
    );

    // ─────────────────────────────────────────────
    //  CONSTRUCTOR
    // ─────────────────────────────────────────────

    constructor(address initialOwner, address _bistTokenAddress)
        Ownable(initialOwner)
    {
        require(_bistTokenAddress != address(0), "Invalid BIST token address");
        bistTokenAddress = _bistTokenAddress;
    }

    // ─────────────────────────────────────────────
    //  DEPOSIT & CREATE VESTING GRANT
    // ─────────────────────────────────────────────

    /**
     * @dev Owner deposits BIST and creates a vesting grant for a recipient.
     * @param recipient             Wallet that will receive tokens after unlock
     * @param amount                Number of BIST tokens to lock
     * @param durationDays          Lock period in days (e.g. 90 for 3 months)
     * @param guaranteeAfterUnlock  If true, owner cannot revoke once unlock occurs.
     *                              Use true for institutional / trust-critical grants;
     *                              false for revocable promotional grants.
     *
     * [L-4] nonReentrant: ERC-1155 safeTransferFrom invokes onERC1155Received
     *       on this contract; the guard prevents any reentrancy concern.
     */
    function depositVesting(
        address recipient,
        uint256 amount,
        uint256 durationDays,
        bool guaranteeAfterUnlock
    ) external onlyOwner nonReentrant {
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be greater than zero");
        require(durationDays > 0, "Duration must be greater than zero");

        IERC1155(bistTokenAddress).safeTransferFrom(
            msg.sender,
            address(this),
            BIST_ID,
            amount,
            ""
        );

        uint256 unlockTime = block.timestamp + (durationDays * 1 days);
        uint256 grantId = grants.length;

        grants.push(VestingGrant({
            recipient:            recipient,
            amount:               amount,
            startTime:            block.timestamp,
            unlockTime:           unlockTime,
            claimed:              false,
            revoked:              false,
            guaranteeAfterUnlock: guaranteeAfterUnlock
        }));

        recipientGrants[recipient].push(grantId);

        emit GrantCreated(grantId, recipient, amount, unlockTime, guaranteeAfterUnlock);
    }

    /**
     * @dev Batch create multiple vesting grants in one transaction.
     *      All grants share the same durationDays and guaranteeAfterUnlock setting.
     *
     * [L-4] nonReentrant.
     */
    function batchDepositVesting(
        address[] calldata recipients,
        uint256[] calldata amounts,
        uint256 durationDays,
        bool guaranteeAfterUnlock
    ) external onlyOwner nonReentrant {
        require(recipients.length == amounts.length, "Length mismatch");
        require(durationDays > 0, "Duration must be greater than zero");

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            require(recipients[i] != address(0), "Invalid recipient");
            require(amounts[i] > 0, "Amount must be greater than zero");
            totalAmount += amounts[i];
        }

        IERC1155(bistTokenAddress).safeTransferFrom(
            msg.sender,
            address(this),
            BIST_ID,
            totalAmount,
            ""
        );

        uint256 unlockTime = block.timestamp + (durationDays * 1 days);

        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 grantId = grants.length;

            grants.push(VestingGrant({
                recipient:            recipients[i],
                amount:               amounts[i],
                startTime:            block.timestamp,
                unlockTime:           unlockTime,
                claimed:              false,
                revoked:              false,
                guaranteeAfterUnlock: guaranteeAfterUnlock
            }));

            recipientGrants[recipients[i]].push(grantId);

            emit GrantCreated(grantId, recipients[i], amounts[i], unlockTime, guaranteeAfterUnlock);
        }
    }

    // ─────────────────────────────────────────────
    //  CLAIM
    // ─────────────────────────────────────────────

    function claim(uint256 grantId) external nonReentrant {
        require(grantId < grants.length, "Invalid grant ID");
        VestingGrant storage grant = grants[grantId];

        require(grant.recipient == msg.sender, "Not the grant recipient");
        require(!grant.claimed, "Already claimed");
        require(!grant.revoked, "Grant has been revoked");
        require(block.timestamp >= grant.unlockTime, "Tokens are still locked");

        grant.claimed = true;

        IERC1155(bistTokenAddress).safeTransferFrom(
            address(this),
            msg.sender,
            BIST_ID,
            grant.amount,
            ""
        );

        emit GrantClaimed(grantId, msg.sender, grant.amount);
    }

    function claimAll() external nonReentrant {
        uint256[] storage myGrants = recipientGrants[msg.sender];
        uint256 totalClaimed = 0;

        for (uint256 i = 0; i < myGrants.length; i++) {
            VestingGrant storage grant = grants[myGrants[i]];
            if (
                !grant.claimed &&
                !grant.revoked &&
                block.timestamp >= grant.unlockTime
            ) {
                grant.claimed = true;
                totalClaimed += grant.amount;
                emit GrantClaimed(myGrants[i], msg.sender, grant.amount);
            }
        }

        require(totalClaimed > 0, "No claimable grants");

        IERC1155(bistTokenAddress).safeTransferFrom(
            address(this),
            msg.sender,
            BIST_ID,
            totalClaimed,
            ""
        );
    }

    // ─────────────────────────────────────────────
    //  ADMIN — REVOKE
    // ─────────────────────────────────────────────

    /**
     * @dev Owner revokes an unclaimed grant and returns tokens to owner.
     *
     * [M-3] If guaranteeAfterUnlock is true on the grant, revocation is
     *       blocked once unlock has occurred. This makes the lock honest:
     *       once a guaranteed grant unlocks, only the recipient can claim
     *       it. Owner can still revoke pre-unlock if needed (e.g. for
     *       compliance or correcting deposit errors).
     */
    function revokeGrant(uint256 grantId) external onlyOwner nonReentrant {
        require(grantId < grants.length, "Invalid grant ID");
        VestingGrant storage grant = grants[grantId];

        require(!grant.claimed, "Already claimed");
        require(!grant.revoked, "Already revoked");

        // [M-3] Block revoke after unlock for guaranteed grants
        if (grant.guaranteeAfterUnlock) {
            require(
                block.timestamp < grant.unlockTime,
                "Grant guaranteed after unlock; cannot revoke"
            );
        }

        grant.revoked = true;

        IERC1155(bistTokenAddress).safeTransferFrom(
            address(this),
            owner(),
            BIST_ID,
            grant.amount,
            ""
        );

        emit GrantRevoked(grantId, grant.recipient, grant.amount);
    }

    // ─────────────────────────────────────────────
    //  VIEW FUNCTIONS
    // ─────────────────────────────────────────────

    function getRecipientGrants(address recipient)
        external view returns (uint256[] memory)
    {
        return recipientGrants[recipient];
    }

    function getGrant(uint256 grantId)
        external view returns (VestingGrant memory)
    {
        require(grantId < grants.length, "Invalid grant ID");
        return grants[grantId];
    }

    function timeUntilUnlock(uint256 grantId)
        external view returns (uint256)
    {
        require(grantId < grants.length, "Invalid grant ID");
        VestingGrant memory grant = grants[grantId];
        if (block.timestamp >= grant.unlockTime) return 0;
        return grant.unlockTime - block.timestamp;
    }

    function claimableAmount(address recipient)
        external view returns (uint256 total)
    {
        uint256[] storage myGrants = recipientGrants[recipient];
        for (uint256 i = 0; i < myGrants.length; i++) {
            VestingGrant memory grant = grants[myGrants[i]];
            if (
                !grant.claimed &&
                !grant.revoked &&
                block.timestamp >= grant.unlockTime
            ) {
                total += grant.amount;
            }
        }
    }

    function totalGrants() external view returns (uint256) {
        return grants.length;
    }
}
