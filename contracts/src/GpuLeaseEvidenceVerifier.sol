// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SlashingTypes} from "./SlashingTypes.sol";
import {IEvidenceVerifier} from "./IEvidenceVerifier.sol";

/// @notice GPU evidence endorsed by a blueprint's designated collector.
/// @dev EvidenceEnvelope.payload is abi.encode(rawPayload, signature); the signature
///      covers evidenceDigest with the raw payload, before wrapping it.
contract GpuLeaseEvidenceVerifier is IEvidenceVerifier {
    struct ExpectedDevice {
        string gpuClass;
        bool teeRequired;
        bytes32 deviceUuid;
    }

    struct ActualDevice {
        string gpuClass;
        bytes32 deviceUuid;
        uint256 memoryMb;
        string driver;
    }

    struct Benchmark {
        uint256 tflops;
        uint256 baselineTflops;
    }

    address public immutable trustedCollector;
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant EVIDENCE_TYPEHASH = keccak256(
        "Evidence(uint8 violation,uint8 kind,uint64 timestamp,address collector,bytes32 payloadHash,bytes32 serviceId,address operator)"
    );
    bytes32 private constant COUNTER_TYPEHASH =
        keccak256("CounterEvidence(bytes32 claimId,uint8 kind,uint64 timestamp,address collector,bytes32 payloadHash)");
    uint256 private constant HALF_ORDER = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    constructor(address collector) {
        require(collector != address(0), "ZERO_COLLECTOR");
        trustedCollector = collector;
    }

    function evidenceDigest(
        SlashingTypes.ViolationType violation,
        SlashingTypes.EvidenceEnvelope memory envelope,
        bytes32 serviceId,
        address operator
    ) public view returns (bytes32) {
        return _digest(
            keccak256(
                abi.encode(
                    EVIDENCE_TYPEHASH,
                    violation,
                    envelope.kind,
                    envelope.timestamp,
                    envelope.collector,
                    keccak256(envelope.payload),
                    serviceId,
                    operator
                )
            )
        );
    }

    function counterDigest(bytes32 claimId, SlashingTypes.EvidenceEnvelope memory envelope)
        public
        view
        returns (bytes32)
    {
        return _digest(
            keccak256(
                abi.encode(
                    COUNTER_TYPEHASH,
                    claimId,
                    envelope.kind,
                    envelope.timestamp,
                    envelope.collector,
                    keccak256(envelope.payload)
                )
            )
        );
    }

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256("GpuLeaseEvidenceVerifier"), keccak256("1"), block.chainid, address(this)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _authenticated(SlashingTypes.EvidenceEnvelope memory envelope, bytes32 digest, bytes memory signature)
        internal
        view
        returns (bool)
    {
        if (
            envelope.collector != trustedCollector || envelope.timestamp == 0 || envelope.timestamp > block.timestamp
                || signature.length != 65
        ) return false;
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        return (v == 27 || v == 28) && uint256(s) <= HALF_ORDER && ecrecover(digest, v, r, s) == trustedCollector;
    }

    function verify(SlashingTypes.ViolationType violation, bytes calldata evidence, bytes32 serviceId, address operator)
        external
        view
        override
        returns (bool valid, uint256 adjustedSeverityBps, string memory description)
    {
        SlashingTypes.EvidenceEnvelope memory envelope = abi.decode(evidence, (SlashingTypes.EvidenceEnvelope));
        bytes memory signature;
        (envelope.payload, signature) = abi.decode(envelope.payload, (bytes, bytes));
        if (!_authenticated(envelope, evidenceDigest(violation, envelope, serviceId, operator), signature)) {
            return (false, 0, "unauthenticated collector evidence");
        }
        if (violation == SlashingTypes.ViolationType.SERVICE_MISMATCH) return _verifyMismatch(envelope);
        SlashingTypes.EvidenceKind expected = SlashingTypes.EvidenceKind.DEVICE_ATTESTATION;
        if (violation == SlashingTypes.ViolationType.SERVICE_UNAVAILABLE) {
            expected = SlashingTypes.EvidenceKind.UPTIME_LOG;
        }
        if (violation == SlashingTypes.ViolationType.LIFECYCLE_VIOLATION) {
            expected = SlashingTypes.EvidenceKind.ACCESS_LOG;
        }
        if (envelope.kind != expected) return (false, 0, "wrong evidence kind");
        return (true, SlashingTypes.defaultSeverityCap(violation), "collector attests to the service violation");
    }

    function verifyCounter(bytes32 claimId, bytes calldata counterEvidence)
        external
        view
        override
        returns (bool valid, string memory description)
    {
        SlashingTypes.EvidenceEnvelope memory envelope = abi.decode(counterEvidence, (SlashingTypes.EvidenceEnvelope));
        bytes memory signature;
        (envelope.payload, signature) = abi.decode(envelope.payload, (bytes, bytes));
        if (!_authenticated(envelope, counterDigest(claimId, envelope), signature)) {
            return (false, "unauthenticated counter-evidence");
        }
        valid = envelope.kind == SlashingTypes.EvidenceKind.OPERATOR_ADMISSION
            || envelope.kind == SlashingTypes.EvidenceKind.THIRD_PARTY_ATTESTATION;
        return (valid, valid ? "collector counter-evidence submitted for review" : "unrecognized counter-evidence kind");
    }

    function _verifyMismatch(SlashingTypes.EvidenceEnvelope memory envelope)
        internal
        pure
        returns (bool, uint256, string memory)
    {
        if (envelope.kind == SlashingTypes.EvidenceKind.PERFORMANCE_BENCHMARK) {
            Benchmark memory bench = abi.decode(envelope.payload, (Benchmark));
            bool degraded = bench.tflops < bench.baselineTflops / 2;
            return (degraded, degraded ? 1500 : 0, "performance compared to class baseline");
        }
        if (envelope.kind != SlashingTypes.EvidenceKind.DEVICE_ATTESTATION) return (false, 0, "wrong evidence kind");
        (ExpectedDevice memory expected, ActualDevice memory actual) =
            abi.decode(envelope.payload, (ExpectedDevice, ActualDevice));
        if (keccak256(bytes(expected.gpuClass)) != keccak256(bytes(actual.gpuClass))) {
            return (true, 2500, "GPU class mismatch");
        }
        if (expected.deviceUuid != bytes32(0) && expected.deviceUuid != actual.deviceUuid) {
            return (true, 2000, "device UUID mismatch");
        }
        return (false, 0, "no mismatch detected");
    }
}
