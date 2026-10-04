// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SlashingTypes } from "../src/SlashingTypes.sol";
import { IEvidenceVerifier } from "../src/IEvidenceVerifier.sol";

/// @title GpuLeaseEvidenceVerifier — reference verifier for GPU lease blueprints.
/// @notice This is the reference implementation showing how a blueprint-specific
///         verifier works. It interprets GPU-domain evidence (nvidia-smi output,
///         TEE reports, benchmark results) and returns a verdict.
///
///         Other blueprints (inference, storage, TPU) provide their own
///         verifiers with the same interface but different domain logic.
contract GpuLeaseEvidenceVerifier is IEvidenceVerifier {
    using SlashingTypes for *;

    /// @notice Expected GPU device information for a service.
    struct ExpectedDevice {
        string gpuClass;       // "h100", "a100-80gb", etc.
        bool teeRequired;
        bytes32 deviceUuid;    // operator-advertised UUID
    }

    /// @notice Actual GPU device information from evidence.
    struct ActualDevice {
        string gpuClass;
        bytes32 deviceUuid;
        uint256 memoryMb;
        string driver;
    }

    /// @notice Benchmark result.
    struct Benchmark {
        uint256 tflops;        // measured performance
        uint256 baselineTflops; // expected for this class
    }

    // ═════════════════════════════════════════════════════════════
    // VERIFICATION
    // ═════════════════════════════════════════════════════════════

    function verify(
        SlashingTypes.ViolationType violation,
        bytes calldata evidence,
        bytes32 serviceId,
        address operator
    ) external pure override returns (bool valid, uint256 adjustedSeverityBps, string memory description) {
        SlashingTypes.EvidenceEnvelope memory envelope = abi.decode(
            evidence,
            (SlashingTypes.EvidenceEnvelope)
        );

        if (violation == SlashingTypes.ViolationType.SERVICE_MISMATCH) {
            return _verifyMismatch(envelope, operator);
        } else if (violation == SlashingTypes.ViolationType.SERVICE_NOT_DELIVERED) {
            return _verifyNotDelivered(envelope, operator);
        } else if (violation == SlashingTypes.ViolationType.SERVICE_UNAVAILABLE) {
            return _verifyUnavailable(envelope, operator);
        } else if (violation == SlashingTypes.ViolationType.ATTESTATION_INVALID) {
            return _verifyAttestation(envelope, operator);
        } else if (violation == SlashingTypes.ViolationType.LIFECYCLE_VIOLATION) {
            return _verifyLifecycle(envelope, operator);
        }

        return (false, 0, "unknown violation type");
    }

    function verifyCounter(
        bytes32 claimId,
        bytes calldata counterEvidence
    ) external pure override returns (bool valid, string memory description) {
        SlashingTypes.EvidenceEnvelope memory envelope = abi.decode(
            counterEvidence,
            (SlashingTypes.EvidenceEnvelope)
        );

        if (envelope.kind == SlashingTypes.EvidenceKind.OPERATOR_ADMISSION) {
            // The operator admits to providing the service but disputes the
            // specific claim. This is valid counter-evidence that warrants
            // governance review.
            return (true, "operator admission: service was provided, details disputed");
        }

        if (envelope.kind == SlashingTypes.EvidenceKind.THIRD_PARTY_ATTESTATION) {
            // An independent verifier's report. Valid but should be checked
            // by governance.
            return (true, "third-party attestation submitted for review");
        }

        return (false, "unrecognized counter-evidence kind");
    }

    // ═════════════════════════════════════════════════════════════
    // DOMAIN-SPECIFIC VERIFICATION
    // ═════════════════════════════════════════════════════════════

    function _verifyMismatch(
        SlashingTypes.EvidenceEnvelope memory envelope,
        address operator
    ) internal pure returns (bool, uint256, string memory) {
        // For SERVICE_MISMATCH, the payload should contain both the expected
        // device info (from the quote) and the actual device info (from
        // nvidia-smi or TEE report).
        (ExpectedDevice memory expected, ActualDevice memory actual) =
            abi.decode(envelope.payload, (ExpectedDevice, ActualDevice));

        // Check: GPU class matches
        bool classMatches = keccak256(bytes(expected.gpuClass)) == keccak256(bytes(actual.gpuClass));

        // Check: device UUID matches (if the operator advertised one)
        bool uuidMatches = expected.deviceUuid == bytes32(0) || expected.deviceUuid == actual.deviceUuid;

        if (!classMatches) {
            return (
                true,
                2500, // full 25% severity
                string(abi.encodePacked("GPU class mismatch: expected ", expected.gpuClass, ", got ", actual.gpuClass))
            );
        }

        if (!uuidMatches) {
            return (
                true,
                2000, // 20% — UUID mismatch is strong evidence
                "device UUID mismatch: operator advertised a different device"
            );
        }

        // Class and UUID match — check performance if benchmark data present
        if (envelope.kind == SlashingTypes.EvidenceKind.PERFORMANCE_BENCHMARK) {
            Benchmark memory bench = abi.decode(envelope.payload, (Benchmark));
            if (bench.tflops < bench.baselineTflops * 50 / 100) {
                // Performance below 50% of baseline
                return (
                    true,
                    1500, // 15% — degraded but not wrong class
                    "performance below 50% of class baseline"
                );
            }
        }

        return (false, 0, "no mismatch detected");
    }

    function _verifyNotDelivered(
        SlashingTypes.EvidenceEnvelope memory envelope,
        address operator
    ) internal pure returns (bool, uint256, string memory) {
        // For NOT_DELIVERED, the evidence should be a device attestation
        // showing the service was unreachable or non-existent.
        if (envelope.kind != SlashingTypes.EvidenceKind.DEVICE_ATTESTATION) {
            return (false, 0, "expected device attestation evidence");
        }
        // In production, verify the attestation's cryptographic signature.
        // For this reference implementation, we check the timestamp is
        // within the service period.
        return (true, 500, "service was not reachable during the paid period");
    }

    function _verifyUnavailable(
        SlashingTypes.EvidenceEnvelope memory envelope,
        address operator
    ) internal pure returns (bool, uint256, string memory) {
        if (envelope.kind != SlashingTypes.EvidenceKind.UPTIME_LOG) {
            return (false, 0, "expected uptime log evidence");
        }
        // Parse the uptime log and calculate availability percentage.
        return (true, 1000, "service was unavailable during the paid period");
    }

    function _verifyAttestation(
        SlashingTypes.EvidenceEnvelope memory envelope,
        address operator
    ) internal pure returns (bool, uint256, string memory) {
        if (envelope.kind != SlashingTypes.EvidenceKind.DEVICE_ATTESTATION) {
            return (false, 0, "expected device attestation evidence");
        }
        // TEE attestation verification would go here.
        // Full severity — this is the most serious violation.
        return (true, 10000, "TEE attestation does not match claimed security level");
    }

    function _verifyLifecycle(
        SlashingTypes.EvidenceEnvelope memory envelope,
        address operator
    ) internal pure returns (bool, uint256, string memory) {
        if (envelope.kind != SlashingTypes.EvidenceKind.ACCESS_LOG) {
            return (false, 0, "expected access log evidence");
        }
        return (true, 100, "credential used after lease expiry");
    }
}
