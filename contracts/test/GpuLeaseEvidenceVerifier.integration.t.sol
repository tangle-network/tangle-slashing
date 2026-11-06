// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GpuLeaseEvidenceVerifier} from "../src/GpuLeaseEvidenceVerifier.sol";
import {SlashingTypes} from "../src/SlashingTypes.sol";

contract GpuLeaseEvidenceIntegrationTest is Test {
    GpuLeaseEvidenceVerifier verifier;
    uint256 constant COLLECTOR_KEY = 0xa11ce;
    bytes32 constant SERVICE = keccak256("lease-1");
    address constant OPERATOR = address(0x1234);

    function setUp() public {
        verifier = new GpuLeaseEvidenceVerifier(vm.addr(COLLECTOR_KEY));
        vm.warp(1_000_000);
    }

    function testBothKindsRequireTheConfiguredCollector() public {
        for (uint8 i; i < 2; ++i) {
            SlashingTypes.ViolationType violation = i == 0
                ? SlashingTypes.ViolationType.SERVICE_NOT_DELIVERED
                : SlashingTypes.ViolationType.SERVICE_UNAVAILABLE;
            SlashingTypes.EvidenceKind kind =
                i == 0 ? SlashingTypes.EvidenceKind.DEVICE_ATTESTATION : SlashingTypes.EvidenceKind.UPTIME_LOG;
            _reject(violation, _envelope(kind, ""), SERVICE, OPERATOR);
            _reject(violation, _envelope(kind, new bytes(65)), SERVICE, OPERATOR);
            SlashingTypes.EvidenceEnvelope memory envelope = _signed(violation, kind, COLLECTOR_KEY);
            (bool valid, uint256 severity,) = verifier.verify(violation, abi.encode(envelope), SERVICE, OPERATOR);
            assertTrue(valid);
            assertEq(severity, i == 0 ? 500 : 1000);
            _reject(violation, _signed(violation, kind, 0xbad), SERVICE, OPERATOR);
            envelope.collector = vm.addr(0xbad);
            envelope.payload = bytes("unreachable");
            envelope.payload =
                abi.encode(envelope.payload, _signature(_digest(violation, envelope, SERVICE, OPERATOR), 0xbad));
            _reject(violation, envelope, SERVICE, OPERATOR);
        }
    }

    function testSignedEnvelopeCannotBeRetargeted() public {
        SlashingTypes.ViolationType violation = SlashingTypes.ViolationType.SERVICE_NOT_DELIVERED;
        SlashingTypes.EvidenceEnvelope memory envelope =
            _signed(violation, SlashingTypes.EvidenceKind.DEVICE_ATTESTATION, COLLECTOR_KEY);
        _reject(violation, envelope, keccak256("another lease"), OPERATOR);
        _reject(violation, envelope, SERVICE, address(0xbeef));
        _reject(SlashingTypes.ViolationType.ATTESTATION_INVALID, envelope, SERVICE, OPERATOR);
        ++envelope.timestamp;
        _reject(violation, envelope, SERVICE, OPERATOR);
        --envelope.timestamp;
        envelope.kind = SlashingTypes.EvidenceKind.UPTIME_LOG;
        _reject(violation, envelope, SERVICE, OPERATOR);
        envelope.kind = SlashingTypes.EvidenceKind.DEVICE_ATTESTATION;
        (, bytes memory signature) = abi.decode(envelope.payload, (bytes, bytes));
        envelope.payload = abi.encode(bytes("different observation"), signature);
        _reject(violation, envelope, SERVICE, OPERATOR);
    }

    function testSignatureCannotCrossVerifierOrChain() public {
        SlashingTypes.ViolationType violation = SlashingTypes.ViolationType.SERVICE_UNAVAILABLE;
        SlashingTypes.EvidenceEnvelope memory envelope =
            _signed(violation, SlashingTypes.EvidenceKind.UPTIME_LOG, COLLECTOR_KEY);
        GpuLeaseEvidenceVerifier other = new GpuLeaseEvidenceVerifier(vm.addr(COLLECTOR_KEY));
        (bool valid, uint256 severity,) = other.verify(violation, abi.encode(envelope), SERVICE, OPERATOR);
        assertFalse(valid);
        assertEq(severity, 0);
        vm.chainId(block.chainid + 1);
        _reject(violation, envelope, SERVICE, OPERATOR);
    }

    function testUnsignedEvidenceCannotChooseAnotherViolation() public view {
        for (uint8 i; i < 5; ++i) {
            _reject(
                SlashingTypes.ViolationType(i),
                _envelope(SlashingTypes.EvidenceKind.DEVICE_ATTESTATION, ""),
                SERVICE,
                OPERATOR
            );
        }
    }

    function testMatchingDevicePayloadDoesNotProveInvalidAttestation() public {
        SlashingTypes.ViolationType violation = SlashingTypes.ViolationType.ATTESTATION_INVALID;
        SlashingTypes.EvidenceEnvelope memory envelope = _envelope(SlashingTypes.EvidenceKind.DEVICE_ATTESTATION, "");
        bytes32 uuid = keccak256("delivered device");
        envelope.payload = abi.encode(
            GpuLeaseEvidenceVerifier.ExpectedDevice("nvidia-h100", false, uuid),
            GpuLeaseEvidenceVerifier.ActualDevice("nvidia-h100", uuid, 80_000, "reported-driver")
        );
        envelope.payload =
            abi.encode(envelope.payload, _signature(_digest(violation, envelope, SERVICE, OPERATOR), COLLECTOR_KEY));
        (bool valid, uint256 severity,) = verifier.verify(violation, abi.encode(envelope), SERVICE, OPERATOR);
        assertFalse(valid, "matching device payload was treated as an invalid attestation");
        assertEq(severity, 0, "no invalid attestation was proven but full stake was recommended");
    }

    function testOpaqueCollectorPayloadDoesNotProveInvalidAttestation() public {
        _reject(
            SlashingTypes.ViolationType.ATTESTATION_INVALID,
            _signed(
                SlashingTypes.ViolationType.ATTESTATION_INVALID,
                SlashingTypes.EvidenceKind.DEVICE_ATTESTATION,
                COLLECTOR_KEY
            ),
            SERVICE,
            OPERATOR
        );
    }

    function testReEncodedEvidenceSharesTheSignedReplayKey() public {
        SlashingTypes.ViolationType violation = SlashingTypes.ViolationType.SERVICE_UNAVAILABLE;
        bytes memory canonical = abi.encode(_signed(violation, SlashingTypes.EvidenceKind.UPTIME_LOG, COLLECTOR_KEY));
        bytes memory padded = bytes.concat(canonical, bytes32(0));
        (bool valid,,) = verifier.verify(violation, padded, SERVICE, OPERATOR);
        assertTrue(valid, "the padded encoding must still verify for this case to matter");
        assertTrue(keccak256(padded) != keccak256(canonical));
        assertEq(
            verifier.replayKey(violation, padded, SERVICE, OPERATOR),
            verifier.replayKey(violation, canonical, SERVICE, OPERATOR)
        );
    }

    function testEvidenceOlderThanTheMaximumAgeIsRejected() public {
        SlashingTypes.ViolationType violation = SlashingTypes.ViolationType.SERVICE_UNAVAILABLE;
        SlashingTypes.EvidenceEnvelope memory envelope =
            _signed(violation, SlashingTypes.EvidenceKind.UPTIME_LOG, COLLECTOR_KEY);
        vm.warp(envelope.timestamp + verifier.MAX_EVIDENCE_AGE());
        (bool valid,,) = verifier.verify(violation, abi.encode(envelope), SERVICE, OPERATOR);
        assertTrue(valid);
        vm.warp(envelope.timestamp + verifier.MAX_EVIDENCE_AGE() + 1);
        _reject(violation, envelope, SERVICE, OPERATOR);
    }

    function testOnlyCollectorAdminCanRotateAndRevokeSigningKeys() public {
        SlashingTypes.ViolationType violation = SlashingTypes.ViolationType.SERVICE_NOT_DELIVERED;
        SlashingTypes.EvidenceEnvelope memory old =
            _signed(violation, SlashingTypes.EvidenceKind.DEVICE_ATTESTATION, COLLECTOR_KEY);
        vm.prank(OPERATOR);
        vm.expectRevert();
        verifier.setCollector(vm.addr(0xbad), true);
        verifier.setCollector(vm.addr(0xbad), true);
        verifier.setCollector(vm.addr(COLLECTOR_KEY), false);
        _reject(violation, old, SERVICE, OPERATOR);
        old.collector = vm.addr(0xbad);
        old.payload = bytes("unreachable");
        old.payload = abi.encode(old.payload, _signature(_digest(violation, old, SERVICE, OPERATOR), 0xbad));
        (bool valid, uint256 severity,) = verifier.verify(violation, abi.encode(old), SERVICE, OPERATOR);
        assertTrue(valid);
        assertEq(severity, 500);
    }

    function _envelope(SlashingTypes.EvidenceKind kind, bytes memory signature)
        internal
        view
        returns (SlashingTypes.EvidenceEnvelope memory)
    {
        return SlashingTypes.EvidenceEnvelope(
            kind, 999_999, vm.addr(COLLECTOR_KEY), abi.encode(bytes("unreachable"), signature)
        );
    }

    function _signed(SlashingTypes.ViolationType violation, SlashingTypes.EvidenceKind kind, uint256 key)
        internal
        returns (SlashingTypes.EvidenceEnvelope memory envelope)
    {
        envelope = _envelope(kind, "");
        envelope.payload = bytes("unreachable");
        bytes32 digest = _digest(violation, envelope, SERVICE, OPERATOR);
        assertEq(verifier.evidenceDigest(violation, envelope, SERVICE, OPERATOR), digest);
        envelope.payload = abi.encode(envelope.payload, _signature(digest, key));
    }

    function _digest(
        SlashingTypes.ViolationType violation,
        SlashingTypes.EvidenceEnvelope memory envelope,
        bytes32 serviceId,
        address operator
    ) internal view returns (bytes32) {
        bytes32 typeHash = keccak256(
            "Evidence(uint8 violation,uint8 kind,uint64 timestamp,address collector,bytes32 payloadHash,bytes32 serviceId,address operator)"
        );
        bytes32 structHash = keccak256(
            abi.encode(
                typeHash,
                violation,
                envelope.kind,
                envelope.timestamp,
                envelope.collector,
                keccak256(envelope.payload),
                serviceId,
                operator
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("GpuLeaseEvidenceVerifier"),
                keccak256("1"),
                block.chainid,
                address(verifier)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _signature(bytes32 digest, uint256 key) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _reject(
        SlashingTypes.ViolationType violation,
        SlashingTypes.EvidenceEnvelope memory envelope,
        bytes32 serviceId,
        address operator
    ) internal view {
        (bool valid, uint256 severity,) = verifier.verify(violation, abi.encode(envelope), serviceId, operator);
        assertFalse(valid, "unauthenticated evidence supports a slash");
        assertEq(severity, 0, "unauthenticated evidence recommends a penalty");
    }
}
