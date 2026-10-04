// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SlashingTypes } from "./SlashingTypes.sol";
import { IEvidenceVerifier } from "./IEvidenceVerifier.sol";

/// @title SlashingHooks — plug tnt-core's native slashing into compute blueprints.
///
/// tnt-core ALREADY has the full slashing lifecycle:
///   proposeSlash → disputeSlash (bonded) → executeSlash
///   with SLASH_ADMIN, dispute windows, commitment tracking, batch execution.
///
/// This contract provides the BSM-side hooks that customize that lifecycle
/// for compute blueprints. Inherit from it in your blueprint's service
/// manager and override the domain-specific parts.
///
/// Usage (in your blueprint's BSM):
/// ```solidity
/// contract MyComputeBlueprint is SlashingHooks {
///     constructor(address slashingRegistry) SlashingHooks(slashingRegistry) {}
/// }
/// ```
///
/// The hooks it implements (from tnt-core's IBlueprintServiceManager):
/// - querySlashingOrigin: lets USERS propose slashes (not just service/blueprint owners)
/// - getSlashingWindow: lets the blueprint set a custom dispute window
/// - queryDisputeOrigin: lets the blueprint designate a dispute resolver
/// - onUnappliedSlash: pre-execution notification (record, don't act)
/// - onSlash: post-execution notification (record the outcome)
abstract contract SlashingHooks {
    /// @notice The evidence verification registry (per-blueprint).
    IEvidenceVerifier public slashingVerifier;

    /// @notice Who can propose slashes. Override to restrict or expand.
    /// @dev Returning address(0) means only the service owner and blueprint
    ///      owner can propose (tnt-core's default).
    ///      Returning a specific address means ONLY that address can propose.
    ///      The most open option: return a mapping-based allowlist.
    mapping(uint64 => address) public slashingOrigins;

    /// @notice Custom dispute window per service. 0 = use tnt-core default.
    mapping(uint64 => uint64) public customDisputeWindows;

    /// @notice Custom dispute origin per service. address(0) = operator only.
    mapping(uint64 => address) public disputeOrigins;

    /// @notice Recorded slash history: operator => (serviceId => count).
    mapping(address => mapping(uint64 => uint256)) public slashHistory;

    /// @notice Total slash events per operator (for reputation).
    mapping(address => uint256) public totalSlashes;

    event SlashProposed(uint64 indexed serviceId, address indexed operator, uint8 slashPercent);
    event SlashExecuted(uint64 indexed serviceId, address indexed operator, uint8 slashPercent);

    constructor(address _slashingVerifier) {
        slashingVerifier = IEvidenceVerifier(_slashingVerifier);
    }

    // ═════════════════════════════════════════════════════════════
    // TNT-CORE HOOKS (called by tnt-core's slashing system)
    // ═════════════════════════════════════════════════════════════

    /// @notice Who can propose slashes for this service.
    /// @dev Called by tnt-core's `proposeSlash`. If this returns a non-zero
    ///      address, that address is authorized to propose. If it returns
    ///      address(0), only svc.owner and bp.owner can propose (default).
    ///
    ///      For compute marketplaces: the LESSEE should be able to propose
    ///      slashes (they're the ones who experienced the service). Override
    ///      this to return a per-service allowlist or a prediction-market
    ///      style "anyone with evidence" model.
    function querySlashingOrigin(uint64 serviceId) external view returns (address slashingOrigin) {
        return slashingOrigins[serviceId];
    }

    /// @notice Custom dispute window for this service.
    /// @dev Called by tnt-core's `proposeSlash` to resolve the window.
    ///      Return (true, 0) to use the protocol default.
    ///      Return (false, N) for a custom N-second window.
    function getSlashingWindow(uint64 serviceId) external view returns (bool useDefault, uint64 window) {
        uint64 custom = customDisputeWindows[serviceId];
        if (custom == 0) {
            return (true, 0); // use tnt-core default
        }
        return (false, custom);
    }

    /// @notice Custom dispute origin for this service.
    /// @dev Called by tnt-core's `disputeSlash`. If non-zero, this address
    ///      can dispute bondlessly (without posting the dispute bond).
    ///      Useful for designating a neutral arbiter.
    function queryDisputeOrigin(uint64 serviceId) external view returns (address disputeOrigin) {
        return disputeOrigins[serviceId];
    }

    /// @notice Pre-execution notification from tnt-core.
    /// @dev Called when a slash is proposed but not yet executed. Record it;
    ///      don't take action (the operator may still dispute).
    function onUnappliedSlash(uint64 serviceId, bytes calldata offender, uint8 slashPercent) external {
        address operator = address(bytes20(offender));
        emit SlashProposed(serviceId, operator, slashPercent);
    }

    /// @notice Post-execution notification from tnt-core.
    /// @dev Called AFTER the slash is executed. This is the definitive outcome.
    function onSlash(uint64 serviceId, bytes calldata offender, uint8 slashPercent) external {
        address operator = address(bytes20(offender));
        slashHistory[operator][serviceId] += 1;
        totalSlashes[operator] += 1;
        emit SlashExecuted(serviceId, operator, slashPercent);
    }

    // ═════════════════════════════════════════════════════════════
    // ADMIN (called by the blueprint owner / governance)
    // ═════════════════════════════════════════════════════════════

    function setSlashingOrigin(uint64 serviceId, address origin) external virtual;
    function setDisputeWindow(uint64 serviceId, uint64 window) external virtual;
    function setDisputeOrigin(uint64 serviceId, address origin) external virtual;
}
