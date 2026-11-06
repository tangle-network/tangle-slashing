// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SlashingTypes} from "./SlashingTypes.sol";
import {IEvidenceVerifier} from "./IEvidenceVerifier.sol";

interface IBlueprintCore {
    function tangleCore() external view returns (address);
}

interface ISlashProposals {
    /// @dev ABI of tnt-core SlashingLib.SlashProposal; `status` is SlashingLib.SlashStatus.
    struct SlashProposal {
        uint64 serviceId;
        address operator;
        address proposer;
        uint16 slashBps;
        uint16 effectiveSlashBps;
        bytes32 evidence;
        uint64 executeAfter;
        uint8 status;
        address disputer;
        uint256 disputeBond;
        uint64 disputeDeadline;
    }

    function proposeSlash(uint64 serviceId, address operator, uint16 severityBps, bytes32 evidenceHash)
        external
        returns (uint64);
    function getSlashProposal(uint64 slashId) external view returns (SlashProposal memory);
}

/// @notice Verified evidence admission into tnt-core's native claim lifecycle.
abstract contract ComputeProviderSlashing {
    address public slashingVerifier;
    // Retain the ordinary slots of retired duplicate policy/reputation mappings.
    uint256[6] private _retiredPolicy;
    mapping(uint64 => mapping(address => bytes32)) public pendingEvidence;
    mapping(bytes32 => bool) public submittedEvidence;
    mapping(uint64 => mapping(address => uint64)) public pendingSlash;
    uint8 private constant SLASH_EXECUTED = 2;
    uint8 private constant SLASH_CANCELLED = 3;

    constructor(address verifier) {
        require(verifier.code.length != 0, "VERIFIER_REQUIRED");
        slashingVerifier = verifier;
    }

    /// @notice The existing envelope's bytes32 serviceId binds core, manager and native ID.
    function evidenceContext(uint64 serviceId) public view returns (bytes32) {
        return keccak256(abi.encode(IBlueprintCore(address(this)).tangleCore(), address(this), serviceId));
    }

    function submitEvidence(
        uint64 serviceId,
        address operator,
        SlashingTypes.ViolationType violation,
        bytes calldata evidence
    ) external returns (bytes32 evidenceHash) {
        ISlashProposals core = ISlashProposals(IBlueprintCore(address(this)).tangleCore());
        // TNT calls no manager hook on cancellation, so the proposal's own status frees the slot.
        if (pendingEvidence[serviceId][operator] != bytes32(0)) {
            uint8 status = core.getSlashProposal(pendingSlash[serviceId][operator]).status;
            require(status == SLASH_EXECUTED || status == SLASH_CANCELLED, "EVIDENCE_PENDING");
        }
        IEvidenceVerifier verifier = IEvidenceVerifier(slashingVerifier);
        bytes32 context = evidenceContext(serviceId);
        (bool valid, uint256 severity,) = verifier.verify(violation, evidence, context, operator);
        require(valid && severity != 0 && severity <= SlashingTypes.defaultSeverityCap(violation), "EVIDENCE_REJECTED");
        // Replay keys on the signed content, so a re-encoding of the same evidence is refused.
        evidenceHash = verifier.replayKey(violation, evidence, context, operator);
        require(!submittedEvidence[evidenceHash], "EVIDENCE_REPLAY");
        pendingEvidence[serviceId][operator] = evidenceHash;
        submittedEvidence[evidenceHash] = true;
        pendingSlash[serviceId][operator] = core.proposeSlash(serviceId, operator, uint16(severity), evidenceHash);
    }

    function _slashingOrigin(uint64) internal view returns (address) {
        return address(this);
    }

    function _slashingWindow(uint64) internal pure returns (bool, uint64) {
        return (true, 0);
    }

    function _disputeOrigin(uint64) internal pure returns (address) {
        return address(0);
    }

    // Native TNT owns proposal events and counters; retain the consumer hook ABI.
    function _recordSlashProposed(uint64, bytes calldata, uint8) internal {}

    function _recordSlashExecuted(uint64 serviceId, bytes calldata offender, uint8) internal {
        delete pendingEvidence[serviceId][address(bytes20(offender))];
    }
}
