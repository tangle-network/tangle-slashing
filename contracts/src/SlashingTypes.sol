// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title SlashingTypes — shared types for the universal slashing framework.
/// @notice These types are used by every compute blueprint on Tangle. The
///         conditions are universal; the evidence is domain-specific.
library SlashingTypes {
    /// @notice The five universal violation conditions (REDTEAM.md §H).
    enum ViolationType {
        SERVICE_NOT_DELIVERED,  // 0: accepted payment, no service provided
        SERVICE_MISMATCH,       // 1: wrong service (GPU class, model, tier)
        SERVICE_UNAVAILABLE,    // 2: downtime during paid period
        ATTESTATION_INVALID,    // 3: security/TEE claim doesn't match reality
        LIFECYCLE_VIOLATION     // 4: operator didn't maintain service lifecycle
    }

    /// @notice A slashing claim submitted by an accuser.
    struct Claim {
        ViolationType violation;
        uint64 blueprintId;      // which blueprint the service belongs to
        bytes32 serviceId;       // the service instance (lease, job, etc.)
        address operator;        // who is accused
        address accuser;         // who submits the evidence
        bytes evidence;          // type-specific, verified by the blueprint's verifier
        uint256 severityBps;     // requested severity (capped by policy)
        uint256 submittedAt;
        uint256 challengeDeadline;
        Status status;
    }

    /// @notice Lifecycle of a claim.
    enum Status {
        Pending,      // challenge period active
        Countered,    // operator responded — requires governance review
        Executed,     // slash applied after unchallenged period
        Dismissed,    // governance dismissed the claim
        Withdrawn     // accuser withdrew
    }

    /// @notice Default challenge period (7 days).
    uint256 public constant CHALLENGE_PERIOD = 7 days;

    /// @notice Default severity caps by violation type (bps of operator stake).
    /// @dev Governance can update these. These are conservative defaults.
    function defaultSeverityCap(ViolationType v) internal pure returns (uint256) {
        if (v == ViolationType.SERVICE_NOT_DELIVERED) return 500;   // 5%
        if (v == ViolationType.SERVICE_MISMATCH) return 2500;       // 25%
        if (v == ViolationType.SERVICE_UNAVAILABLE) return 1000;    // 10%
        if (v == ViolationType.ATTESTATION_INVALID) return 10000;   // 100% (eject)
        if (v == ViolationType.LIFECYCLE_VIOLATION) return 100;     // 1%
        return 0;
    }

    /// @notice The canonical evidence envelope. All evidence must be wrapped
    ///         in this structure so the verifier knows what it's looking at.
    struct EvidenceEnvelope {
        EvidenceKind kind;
        uint64 timestamp;       // when the evidence was collected
        address collector;      // who collected it (for signature verification)
        bytes payload;          // the actual evidence (kind-specific)
    }

    /// @notice Standard evidence kinds. Each blueprint maps these to its
    ///         domain-specific verification logic.
    enum EvidenceKind {
        DEVICE_ATTESTATION,     // nvidia-smi, TEE report, device UUID
        PERFORMANCE_BENCHMARK,  // benchmark results with baseline comparison
        UPTIME_LOG,             // availability timestamps
        ACCESS_LOG,             // credential usage with timestamps
        OFF_CHAIN_RECEIPT,      // proof of off-chain action (e.g. Stripe payment)
        OPERATOR_ADMISSION,     // operator's own logs/attestation (for counter-evidence)
        THIRD_PARTY_ATTESTATION // independent verifier's report
    }
}
