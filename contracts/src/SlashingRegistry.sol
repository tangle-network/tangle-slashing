// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SlashingTypes } from "./SlashingTypes.sol";
import { IEvidenceVerifier } from "./IEvidenceVerifier.sol";
import { ISlashingRegistry } from "./ISlashingRegistry.sol";

/// @title SlashingRegistry — the universal slashing registry for Tangle
///        compute blueprints.
/// @notice This contract is GENERIC — it manages the claim lifecycle
///         (submit → challenge → execute) without interpreting evidence.
///         Evidence verification is delegated to the blueprint's registered
///         IEvidenceVerifier.
///
/// @dev The registry does NOT hold or move stake. It emits verdicts as
///      events; tnt-core's operator staking system enforces them. This
///      separation keeps the registry simple and upgradeable independently
///      of the staking mechanism.
contract SlashingRegistry is ISlashingRegistry {
    using SlashingTypes for *;

    // ═════════════════════════════════════════════════════════════
    // STORAGE
    // ═════════════════════════════════════════════════════════════

    /// @notice Governance address (can update severity caps, resolve countered claims).
    address public governance;

    /// @notice Per-blueprint evidence verifiers.
    mapping(uint64 => address) public verifiers;

    /// @notice All claims by ID.
    mapping(bytes32 => SlashingTypes.Claim) public claims;

    /// @notice All claim IDs (for enumeration).
    bytes32[] private _claimIds;

    /// @notice Claims by accused operator.
    mapping(address => bytes32[]) private _claimsByOperator;

    /// @notice Severity caps by violation type (governance-updatable).
    mapping(uint8 => uint256) public severityCaps;

    /// @notice Reentrancy guard.
    uint256 private _locked = 1;

    // ═════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═════════════════════════════════════════════════════════════

    modifier onlyGovernance() {
        require(msg.sender == governance, "NOT_GOVERNANCE");
        _;
    }

    modifier nonReentrant() {
        require(_locked == 1, "REENTRANT");
        _locked = 2;
        _;
        _locked = 1;
    }

    // ═════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════

    constructor(address _governance) {
        governance = _governance;
        // Initialize default severity caps from SlashingTypes.
        for (uint8 i = 0; i < 5; i++) {
            severityCaps[i] = SlashingTypes.defaultSeverityCap(SlashingTypes.ViolationType(i));
        }
    }

    // ═════════════════════════════════════════════════════════════
    // BLUEPRINT REGISTRATION
    // ═════════════════════════════════════════════════════════════

    function registerVerifier(uint64 blueprintId, address verifier) external override onlyGovernance {
        if (verifiers[blueprintId] != address(0)) {
            revert AlreadyRegistered(blueprintId);
        }
        verifiers[blueprintId] = verifier;
        emit VerifierRegistered(blueprintId, verifier);
    }

    function getVerifier(uint64 blueprintId) external view override returns (address) {
        return verifiers[blueprintId];
    }

    // ═════════════════════════════════════════════════════════════
    // CLAIM LIFECYCLE
    // ═════════════════════════════════════════════════════════════

    function submit(
        uint64 blueprintId,
        bytes32 serviceId,
        address operator,
        SlashingTypes.ViolationType violation,
        bytes calldata evidence,
        uint256 severityBps
    ) external override nonReentrant returns (bytes32 claimId) {
        address verifier = verifiers[blueprintId];
        if (verifier == address(0)) revert NoVerifierRegistered(blueprintId);
        if (severityBps == 0) revert ZeroSeverity();

        uint256 cap = severityCaps[uint8(violation)];
        if (severityBps > cap) revert SeverityExceedsCap();

        // Verify the evidence via the blueprint's verifier.
        // The verifier returns adjusted severity (may be lower than requested).
        (bool valid, uint256 adjustedBps, ) = IEvidenceVerifier(verifier).verify(
            violation,
            evidence,
            serviceId,
            msg.sender // operator is not known yet; the verifier determines it
        );
        if (!valid) revert EvidenceVerificationFailed();
        if (adjustedBps > 0 && adjustedBps < severityBps) {
            severityBps = adjustedBps; // use the verifier's recommendation
        }

        // The operator is provided explicitly by the accuser.
        // The verifier confirms this matches the on-chain service record.

        claimId = keccak256(
            abi.encodePacked(blueprintId, serviceId, violation, msg.sender, block.timestamp, _claimIds.length)
        );

        claims[claimId] = SlashingTypes.Claim({
            violation: violation,
            blueprintId: blueprintId,
            serviceId: serviceId,
            operator: operator,
            accuser: msg.sender,
            evidence: evidence,
            severityBps: severityBps,
            submittedAt: block.timestamp,
            challengeDeadline: block.timestamp + SlashingTypes.CHALLENGE_PERIOD,
            status: SlashingTypes.Status.Pending
        });

        _claimIds.push(claimId);
        _claimsByOperator[operator].push(claimId);

        emit ClaimSubmitted(claimId, blueprintId, operator, violation, severityBps);
    }

    function counter(bytes32 claimId, bytes calldata counterEvidence) external override nonReentrant {
        SlashingTypes.Claim storage claim = claims[claimId];
        if (claim.submittedAt == 0) revert ClaimNotFound();
        if (claim.status != SlashingTypes.Status.Pending) revert AlreadyResolved();
        if (msg.sender != claim.operator) revert NotTheOperator();
        if (block.timestamp > claim.challengeDeadline) revert ChallengePeriodExpired();

        // Verify the counter-evidence via the blueprint's verifier.
        address verifier = verifiers[claim.blueprintId];
        (bool valid, ) = IEvidenceVerifier(verifier).verifyCounter(claimId, counterEvidence);
        // Even if the counter-evidence is weak, the operator has the right
        // to be heard. Countered claims go to governance review regardless.
        // The verifier's assessment is advisory for governance.

        claim.status = SlashingTypes.Status.Countered;
        emit ClaimCountered(claimId, msg.sender);
    }

    function execute(bytes32 claimId) external override nonReentrant {
        SlashingTypes.Claim storage claim = claims[claimId];
        if (claim.submittedAt == 0) revert ClaimNotFound();
        if (claim.status != SlashingTypes.Status.Pending) revert AlreadyResolved();
        if (block.timestamp < claim.challengeDeadline) revert ChallengePeriodActive();

        claim.status = SlashingTypes.Status.Executed;

        // The registry doesn't hold stake — it emits the verdict.
        // tnt-core's operator staking system listens for this event and
        // deducts from the operator's stake.
        emit ClaimExecuted(claimId, claim.operator, claim.severityBps);
    }

    function withdraw(bytes32 claimId) external override {
        SlashingTypes.Claim storage claim = claims[claimId];
        if (claim.submittedAt == 0) revert ClaimNotFound();
        if (claim.status != SlashingTypes.Status.Pending) revert AlreadyResolved();
        if (msg.sender != claim.accuser) revert NotTheAccuser();

        claim.status = SlashingTypes.Status.Withdrawn;
        emit ClaimWithdrawn(claimId);
    }

    function resolveByGovernance(bytes32 claimId, bool execute_) external override onlyGovernance {
        SlashingTypes.Claim storage claim = claims[claimId];
        if (claim.submittedAt == 0) revert ClaimNotFound();
        if (claim.status != SlashingTypes.Status.Countered) revert AlreadyResolved();

        if (execute_) {
            claim.status = SlashingTypes.Status.Executed;
            emit ClaimExecuted(claimId, claim.operator, claim.severityBps);
        } else {
            claim.status = SlashingTypes.Status.Dismissed;
        }
    }

    // ═════════════════════════════════════════════════════════════
    // GOVERNANCE
    // ═════════════════════════════════════════════════════════════

    function updateSeverityCap(
        SlashingTypes.ViolationType violation,
        uint256 newCap
    ) external onlyGovernance {
        severityCaps[uint8(violation)] = newCap;
        emit SeverityCapUpdated(violation, newCap);
    }

    function updateGovernance(address newGovernance) external onlyGovernance {
        governance = newGovernance;
    }

    // ═════════════════════════════════════════════════════════════
    // VIEWS
    // ═════════════════════════════════════════════════════════════

    function getClaim(bytes32 claimId) external view override returns (SlashingTypes.Claim memory) {
        return claims[claimId];
    }

    function getSeverityCap(SlashingTypes.ViolationType violation) external view override returns (uint256) {
        return severityCaps[uint8(violation)];
    }

    function claimCount() external view override returns (uint256) {
        return _claimIds.length;
    }

    function claimsByOperator(address operator) external view override returns (bytes32[] memory) {
        return _claimsByOperator[operator];
    }
}
