// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SlashingTypes } from "./SlashingTypes.sol";

/// @title ISlashingRegistry — the universal slashing interface.
/// @notice Any compute blueprint on Tangle can import this interface and
///         register with the registry. Users submit claims, operators counter,
///         and after the challenge period, uncountered claims execute.
interface ISlashingRegistry {
    // ═════════════════════════════════════════════════════════════
    // EVENTS
    // ═════════════════════════════════════════════════════════════

    event ClaimSubmitted(
        bytes32 indexed claimId,
        uint64 indexed blueprintId,
        address indexed operator,
        SlashingTypes.ViolationType violation,
        uint256 severityBps
    );

    event ClaimCountered(
        bytes32 indexed claimId,
        address indexed operator
    );

    event ClaimExecuted(
        bytes32 indexed claimId,
        address indexed operator,
        uint256 severityBps
    );

    event ClaimWithdrawn(bytes32 indexed claimId);

    event VerifierRegistered(
        uint64 indexed blueprintId,
        address indexed verifier
    );

    event SeverityCapUpdated(
        SlashingTypes.ViolationType violation,
        uint256 newCap
    );

    // ═════════════════════════════════════════════════════════════
    // ERRORS
    // ═════════════════════════════════════════════════════════════

    error ClaimNotFound();
    error ChallengePeriodActive();
    error ChallengePeriodExpired();
    error AlreadyResolved();
    error NotTheAccuser();
    error NotTheOperator();
    error SeverityExceedsCap();
    error ZeroSeverity();
    error NoVerifierRegistered(uint64 blueprintId);
    error EvidenceVerificationFailed();
    error AlreadyRegistered(uint64 blueprintId);

    // ═════════════════════════════════════════════════════════════
    // BLUEPRINT REGISTRATION
    // ═════════════════════════════════════════════════════════════

    /// @notice Register a domain-specific evidence verifier for a blueprint.
    /// @param blueprintId The tnt-core blueprint ID
    /// @param verifier The IEvidenceVerifier implementation
    function registerVerifier(uint64 blueprintId, address verifier) external;

    /// @notice Get the registered verifier for a blueprint.
    function getVerifier(uint64 blueprintId) external view returns (address);

    // ═════════════════════════════════════════════════════════════
    // CLAIM LIFECYCLE
    // ═════════════════════════════════════════════════════════════

    /// @notice Submit a slashing claim against an operator.
    /// @param blueprintId The blueprint the service belongs to
    /// @param serviceId The service instance (lease ID, job ID, etc.)
    /// @param violation The violation type
    /// @param evidence Domain-specific evidence (see EvidenceEnvelope)
    /// @param severityBps Requested severity (capped by policy)
    /// @return claimId Unique identifier for this claim
    function submit(
        uint64 blueprintId,
        bytes32 serviceId,
        address operator,
        SlashingTypes.ViolationType violation,
        bytes calldata evidence,
        uint256 severityBps
    ) external returns (bytes32 claimId);

    /// @notice Operator submits counter-evidence during the challenge period.
    /// @param claimId The claim being countered
    /// @param counterEvidence Domain-specific counter-evidence
    function counter(bytes32 claimId, bytes calldata counterEvidence) external;

    /// @notice Execute a slash after the challenge period (permissionless).
    ///         Only works for uncountered claims. Countered claims go to
    ///         governance review via `resolveByGovernance`.
    function execute(bytes32 claimId) external;

    /// @notice Accuser withdraws their claim.
    function withdraw(bytes32 claimId) external;

    /// @notice Governance resolves a countered claim.
    /// @param claimId The countered claim
    /// @param execute Whether to execute the slash or dismiss
    function resolveByGovernance(bytes32 claimId, bool execute) external;

    // ═════════════════════════════════════════════════════════════
    // VIEWS
    // ═════════════════════════════════════════════════════════════

    function getClaim(bytes32 claimId) external view returns (SlashingTypes.Claim memory);
    function getSeverityCap(SlashingTypes.ViolationType violation) external view returns (uint256);
    function claimCount() external view returns (uint256);
    function claimsByOperator(address operator) external view returns (bytes32[] memory);
}
