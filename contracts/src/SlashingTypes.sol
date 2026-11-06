// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library SlashingTypes {
    /// @notice The five universal violation conditions (REDTEAM.md §H).
    enum ViolationType {
        SERVICE_NOT_DELIVERED, // 0: accepted payment, no service provided
        SERVICE_MISMATCH, // 1: wrong service (GPU class, model, tier)
        SERVICE_UNAVAILABLE, // 2: downtime during paid period
        ATTESTATION_INVALID, // 3: security/TEE claim doesn't match reality
        LIFECYCLE_VIOLATION // 4: operator didn't maintain service lifecycle
    }

    /// @notice Default severity caps by violation type (bps of operator stake).
    /// @dev Governance can update these. These are conservative defaults.
    function defaultSeverityCap(ViolationType v) internal pure returns (uint256) {
        if (v == ViolationType.SERVICE_NOT_DELIVERED) return 500; // 5%
        if (v == ViolationType.SERVICE_MISMATCH) return 2500; // 25%
        if (v == ViolationType.SERVICE_UNAVAILABLE) return 1000; // 10%
        if (v == ViolationType.ATTESTATION_INVALID) return 10000; // 100% (eject)
        if (v == ViolationType.LIFECYCLE_VIOLATION) return 100; // 1%
        return 0;
    }

    /// @notice Evidence context; GPU payloads wrap raw domain data and its signature.
    struct EvidenceEnvelope {
        EvidenceKind kind;
        uint64 timestamp; // when the evidence was collected
        address collector; // who collected it (for signature verification)
        bytes payload; // the actual evidence (kind-specific)
    }

    enum EvidenceKind {
        DEVICE_ATTESTATION, // nvidia-smi, TEE report, device UUID
        PERFORMANCE_BENCHMARK, // benchmark results with baseline comparison
        UPTIME_LOG, // availability timestamps
        ACCESS_LOG, // credential usage with timestamps
        OFF_CHAIN_RECEIPT, // proof of off-chain action (e.g. Stripe payment)
        OPERATOR_ADMISSION, // operator's own logs/attestation (for counter-evidence)
        THIRD_PARTY_ATTESTATION // independent verifier's report
    }
}
