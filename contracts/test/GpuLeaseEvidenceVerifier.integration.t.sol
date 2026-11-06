// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { GpuLeaseEvidenceVerifier } from "../src/GpuLeaseEvidenceVerifier.sol";
import { SlashingTypes } from "../src/SlashingTypes.sol";

contract GpuLeaseEvidenceIntegrationTest is Test {
    GpuLeaseEvidenceVerifier verifier;
    bytes32 constant SERVICE = keccak256("lease-1");
    address constant OPERATOR = address(0x1234);

    function setUp() public {
        verifier = new GpuLeaseEvidenceVerifier();
    }

    function testUnsignedDeviceAttestationCannotSlash() public view {
        _reject(SlashingTypes.ViolationType.SERVICE_NOT_DELIVERED, SlashingTypes.EvidenceKind.DEVICE_ATTESTATION, "");
    }

    function testWronglySignedUptimeLogCannotSlash() public view {
        _reject(SlashingTypes.ViolationType.SERVICE_UNAVAILABLE, SlashingTypes.EvidenceKind.UPTIME_LOG, new bytes(65));
    }

    function _reject(SlashingTypes.ViolationType violation, SlashingTypes.EvidenceKind kind, bytes memory signature)
        internal view
    {
        SlashingTypes.EvidenceEnvelope memory envelope = SlashingTypes.EvidenceEnvelope({
            kind: kind, timestamp: 1, collector: address(0x5678), payload: abi.encode(bytes("unreachable"), signature)
        });
        (bool valid, uint256 severity,) = verifier.verify(violation, abi.encode(envelope), SERVICE, OPERATOR);
        assertFalse(valid, "unauthenticated evidence supports a slash");
        assertEq(severity, 0, "unauthenticated evidence recommends a penalty");
    }
}
