// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SlashingTypes } from "./SlashingTypes.sol";

/// @title IEvidenceVerifier — domain-specific evidence verification.
/// @notice Each compute blueprint registers a verifier with the
///         SlashingRegistry. The verifier interprets the evidence for that
///         blueprint's domain (GPU identity, model output, storage proof).
///
///         The registry is GENERIC — it doesn't interpret evidence. The
///         verifier is SPECIFIC — it knows what valid evidence looks like.
interface IEvidenceVerifier {
    /// @notice Verify evidence for a slashing claim.
    /// @param violation The type of violation being claimed
    /// @param evidence The evidence envelope (see SlashingTypes.EvidenceEnvelope)
    /// @param serviceId The service instance this claim relates to
    /// @param operator The accused operator
    /// @return valid Whether the evidence supports the accusation
    /// @return adjustedSeverityBps The verifier's recommended severity
    ///         (may be lower than requested; never higher than the cap)
    /// @return description Human-readable summary for governance review
    function verify(
        SlashingTypes.ViolationType violation,
        bytes calldata evidence,
        bytes32 serviceId,
        address operator
    ) external view returns (
        bool valid,
        uint256 adjustedSeverityBps,
        string memory description
    );

    /// @notice Verify counter-evidence submitted by the accused operator.
    /// @return valid Whether the counter-evidence refutes the original claim
    /// @return description Human-readable summary
    function verifyCounter(
        bytes32 claimId,
        bytes calldata counterEvidence
    ) external view returns (
        bool valid,
        string memory description
    );
}
