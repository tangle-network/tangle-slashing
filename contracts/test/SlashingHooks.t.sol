// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { SlashingTypes } from "../src/SlashingTypes.sol";
import { SlashingHooks } from "../src/SlashingHooks.sol";
import { GpuLeaseEvidenceVerifier } from "../src/GpuLeaseEvidenceVerifier.sol";

/// @notice A concrete implementation of SlashingHooks for testing.
contract TestComputeBSM is SlashingHooks {
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    constructor(address verifier) SlashingHooks(verifier) {
        owner = msg.sender;
    }

    function setSlashingOrigin(uint64 serviceId, address origin) external override onlyOwner {
        slashingOrigins[serviceId] = origin;
    }

    function setDisputeWindow(uint64 serviceId, uint64 window) external override onlyOwner {
        customDisputeWindows[serviceId] = window;
    }

    function setDisputeOrigin(uint64 serviceId, address origin) external override onlyOwner {
        disputeOrigins[serviceId] = origin;
    }
}

contract SlashingHooksTest is Test {
    TestComputeBSM public bsm;
    GpuLeaseEvidenceVerifier public verifier;

    address public owner = makeAddr("owner");
    address public operator = makeAddr("operator");
    address public lessee = makeAddr("lessee");
    address public arbiter = makeAddr("arbiter");
    uint64 public serviceId = 42;

    function setUp() public {
        verifier = new GpuLeaseEvidenceVerifier();
        vm.prank(owner);
        bsm = new TestComputeBSM(address(verifier));
    }

    // ── querySlashingOrigin ────────────────────────────────────

    function test_DefaultSlashingOriginIsZero() public view {
        // Zero means only svc.owner / bp.owner can propose (tnt-core default)
        assertEq(bsm.querySlashingOrigin(serviceId), address(0));
    }

    function test_SetSlashingOrigin() public {
        vm.prank(owner);
        bsm.setSlashingOrigin(serviceId, lessee);
        assertEq(bsm.querySlashingOrigin(serviceId), lessee);
    }

    function test_OnlyOwnerCanSetSlashingOrigin() public {
        vm.prank(lessee);
        vm.expectRevert("NOT_OWNER");
        bsm.setSlashingOrigin(serviceId, lessee);
    }

    // ── getSlashingWindow ──────────────────────────────────────

    function test_DefaultDisputeWindowIsProtocolDefault() public view {
        (bool useDefault, uint256 window) = bsm.getSlashingWindow(serviceId);
        assertTrue(useDefault);
        assertEq(window, 0);
    }

    function test_CustomDisputeWindow() public {
        vm.prank(owner);
        bsm.setDisputeWindow(serviceId, 3 days);
        (bool useDefault, uint256 window) = bsm.getSlashingWindow(serviceId);
        assertFalse(useDefault);
        assertEq(window, 3 days);
    }

    // ── queryDisputeOrigin ─────────────────────────────────────

    function test_DefaultDisputeOriginIsZero() public view {
        assertEq(bsm.queryDisputeOrigin(serviceId), address(0));
    }

    function test_SetDisputeOrigin() public {
        vm.prank(owner);
        bsm.setDisputeOrigin(serviceId, arbiter);
        assertEq(bsm.queryDisputeOrigin(serviceId), arbiter);
    }

    // ── onSlash hooks ──────────────────────────────────────────

    function test_OnUnappliedSlashEmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit SlashingHooks.SlashProposed(serviceId, operator, 25);
        bsm.onUnappliedSlash(serviceId, abi.encodePacked(operator), 25);
    }

    function test_OnSlashRecordsHistory() public {
        bsm.onSlash(serviceId, abi.encodePacked(operator), 25);
        assertEq(bsm.slashHistory(operator, serviceId), 1);
        assertEq(bsm.totalSlashes(operator), 1);

        bsm.onSlash(serviceId, abi.encodePacked(operator), 10);
        assertEq(bsm.slashHistory(operator, serviceId), 2);
        assertEq(bsm.totalSlashes(operator), 2);
    }

    function test_OnSlashEmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit SlashingHooks.SlashExecuted(serviceId, operator, 25);
        bsm.onSlash(serviceId, abi.encodePacked(operator), 25);
    }

    // ── verifier integration ───────────────────────────────────

    function test_VerifierIsSet() public view {
        assertEq(address(bsm.slashingVerifier()), address(verifier));
    }

    // ── severity caps ──────────────────────────────────────────

    function test_SeverityCapsAreCorrect() public pure {
        assertEq(SlashingTypes.defaultSeverityCap(SlashingTypes.ViolationType.SERVICE_NOT_DELIVERED), 500);
        assertEq(SlashingTypes.defaultSeverityCap(SlashingTypes.ViolationType.SERVICE_MISMATCH), 2500);
        assertEq(SlashingTypes.defaultSeverityCap(SlashingTypes.ViolationType.SERVICE_UNAVAILABLE), 1000);
        assertEq(SlashingTypes.defaultSeverityCap(SlashingTypes.ViolationType.ATTESTATION_INVALID), 10000);
        assertEq(SlashingTypes.defaultSeverityCap(SlashingTypes.ViolationType.LIFECYCLE_VIOLATION), 100);
    }
}
