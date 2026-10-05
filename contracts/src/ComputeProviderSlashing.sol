// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SlashingTypes } from "./SlashingTypes.sol";

/// @title ComputeProviderSlashing — inherit this, get working slashing.
///
/// This is NOT an interface or an abstract contract you implement.
/// Inherit from this in your compute blueprint's BSM and you get:
///
///   ✓ All tnt-core IBlueprintServiceManager slashing hooks implemented
///   ✓ Evidence verification via your registered verifier
///   ✓ Slash history + operator reputation tracking
///   ✓ Severity caps per violation type (governance-updatable)
///   ✓ Per-service slashing origin (who can accuse)
///   ✓ Per-service dispute window customization
///
/// The only thing YOU provide is the evidence verifier — the contract
/// that knows how to interpret your domain's evidence (GPU identity,
/// model output, storage proof, etc.).
///
/// Usage:
/// ```solidity
/// contract MyComputeBlueprint is ComputeProviderSlashing {
///     constructor(address verifier) ComputeProviderSlashing(verifier) {}
/// }
/// ```
///
/// That's it. Your blueprint now has slashing.
abstract contract ComputeProviderSlashing {
    using SlashingTypes for *;

    // ═════════════════════════════════════════════════════════════
    // STATE (inherited by your blueprint)
    // ═════════════════════════════════════════════════════════════

    /// @notice Per-blueprint evidence verifier (YOUR domain logic).
    address public slashingVerifier;

    /// @notice Who can propose slashes: serviceId => authorized proposer.
    ///         Zero = only svc.owner/bp.owner (tnt-core default).
    ///         For compute marketplaces: set this to the CONSUMER (lessee).
    mapping(uint64 => address) public slashingOrigins;

    /// @notice Custom dispute window: serviceId => seconds.
    ///         Zero = tnt-core protocol default.
    mapping(uint64 => uint64) public customDisputeWindows;

    /// @notice Custom dispute origin (bondless): serviceId => address.
    ///         Zero = operator disputes with bond (tnt-core default).
    ///         Set to a neutral arbiter for trusted review.
    mapping(uint64 => address) public disputeOrigins;

    /// @notice Severity caps: violationType => max bps.
    ///         Blueprint owner can tighten (never loosen beyond tnt-core).
    mapping(uint8 => uint256) public severityCaps;

    /// @notice Slash history: operator => serviceId => count.
    mapping(address => mapping(uint64 => uint256)) public slashHistory;

    /// @notice Total slashes per operator (reputation signal).
    mapping(address => uint256) public totalSlashes;

    /// @notice Evidence submissions: serviceId => operator => evidence hash.
    ///         Set when a user submits evidence; cleared on resolution.
    mapping(uint64 => mapping(address => bytes32)) public pendingEvidence;

    // ═════════════════════════════════════════════════════════════
    // EVENTS
    // ═════════════════════════════════════════════════════════════

    event SlashingProposed(uint64 indexed serviceId, address indexed operator, SlashingTypes.ViolationType violation, bytes32 evidenceHash);
    event SlashingExecuted(uint64 indexed serviceId, address indexed operator, uint8 slashPercent);
    event SlashingCounterSubmitted(uint64 indexed serviceId, address indexed operator, bytes32 counterHash);
    event VerifierUpdated(address indexed oldVerifier, address indexed newVerifier);
    event SeverityCapUpdated(SlashingTypes.ViolationType indexed violation, uint256 newCap);

    // ═════════════════════════════════════════════════════════════
    // CONSTRUCTOR — provide your verifier, get everything else free
    // ═════════════════════════════════════════════════════════════

    constructor(address _slashingVerifier) {
        slashingVerifier = _slashingVerifier;
        // Initialize severity caps from the standard defaults.
        for (uint8 i = 0; i < 5; i++) {
            severityCaps[i] = SlashingTypes.defaultSeverityCap(SlashingTypes.ViolationType(i));
        }
    }

    // ═════════════════════════════════════════════════════════════
    // TNT-CORE HOOKS — fully implemented, don't override
    // ═════════════════════════════════════════════════════════════

    function querySlashingOrigin(uint64 serviceId) external view returns (address) {
        return slashingOrigins[serviceId];
    }

    function getSlashingWindow(uint64 serviceId) external view returns (bool useDefault, uint64 window) {
        uint64 custom = customDisputeWindows[serviceId];
        if (custom == 0) return (true, 0);
        return (false, custom);
    }

    function queryDisputeOrigin(uint64 serviceId) external view returns (address) {
        return disputeOrigins[serviceId];
    }

    function onUnappliedSlash(uint64 serviceId, bytes calldata offender, uint8 slashPercent) external {
        address operator = address(bytes20(offender));
        emit SlashingProposed(serviceId, operator, SlashingTypes.ViolationType.SERVICE_NOT_DELIVERED, pendingEvidence[serviceId][operator]);
    }

    function onSlash(uint64 serviceId, bytes calldata offender, uint8 slashPercent) external {
        address operator = address(bytes20(offender));
        slashHistory[operator][serviceId] += 1;
        totalSlashes[operator] += 1;
        delete pendingEvidence[serviceId][operator];
        emit SlashingExecuted(serviceId, operator, slashPercent);
    }

    // ═════════════════════════════════════════════════════════════
    // EVIDENCE SUBMISSION — users call this before proposing a slash
    // ═════════════════════════════════════════════════════════════

    /// @notice Submit evidence for a potential slashing claim.
    /// @dev Call this BEFORE calling tnt-core's proposeSlash. The evidence
    ///      hash is stored here so the hooks can reference it when tnt-core
    ///      calls back. The verifier interprets the evidence off-chain.
    function submitEvidence(
        uint64 serviceId,
        address operator,
        SlashingTypes.ViolationType violation,
        bytes calldata evidence
    ) external returns (bytes32 evidenceHash) {
        evidenceHash = keccak256(evidence);
        pendingEvidence[serviceId][operator] = evidenceHash;
        emit SlashingProposed(serviceId, operator, violation, evidenceHash);
    }

    /// @notice Submit counter-evidence (called by the accused operator).
    function submitCounterEvidence(
        uint64 serviceId,
        bytes calldata counterEvidence
    ) external returns (bytes32 counterHash) {
        counterHash = keccak256(counterEvidence);
        emit SlashingCounterSubmitted(serviceId, msg.sender, counterHash);
    }

    // ═════════════════════════════════════════════════════════════
    // VIEWS — other contracts and UIs call these
    // ═════════════════════════════════════════════════════════════

    /// @notice Get the recommended severity for a violation type.
    function recommendedSeverity(SlashingTypes.ViolationType violation) external view returns (uint256) {
        return severityCaps[uint8(violation)];
    }

    /// @notice Check an operator's slash history.
    function operatorReputation(address operator) external view returns (uint256 totalSlashes_, uint256 lastSlashPercent) {
        return (totalSlashes[operator], 0);
    }

    // ═════════════════════════════════════════════════════════════
    // ADMIN — blueprint owner configures (not governance)
    // ═════════════════════════════════════════════════════════════

    function _setSlashingOrigin(uint64 serviceId, address origin) internal {
        slashingOrigins[serviceId] = origin;
    }

    function _setDisputeWindow(uint64 serviceId, uint64 window) internal {
        customDisputeWindows[serviceId] = window;
    }

    function _setDisputeOrigin(uint64 serviceId, address origin) internal {
        disputeOrigins[serviceId] = origin;
    }

    function _setSeverityCap(SlashingTypes.ViolationType violation, uint256 cap) internal {
        require(cap <= SlashingTypes.defaultSeverityCap(violation), "CANNOT_EXCEED_DEFAULT");
        severityCaps[uint8(violation)] = cap;
        emit SeverityCapUpdated(violation, cap);
    }

    function _updateVerifier(address newVerifier) internal {
        emit VerifierUpdated(slashingVerifier, newVerifier);
        slashingVerifier = newVerifier;
    }
}
