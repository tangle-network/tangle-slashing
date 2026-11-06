// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SlashingTypes} from "./SlashingTypes.sol";

/// @notice Evidence records, severity policy, and internal tnt-core hook helpers.
abstract contract ComputeProviderSlashing {
    address public slashingVerifier;

    mapping(uint64 => address) public slashingOrigins;

    mapping(uint64 => uint64) public customDisputeWindows;

    mapping(uint64 => address) public disputeOrigins;

    mapping(uint8 => uint256) public severityCaps;

    mapping(address => mapping(uint64 => uint256)) public slashHistory;

    mapping(address => uint256) public totalSlashes;

    mapping(uint64 => mapping(address => bytes32)) public pendingEvidence;

    event SlashingProposed(
        uint64 indexed serviceId, address indexed operator, SlashingTypes.ViolationType violation, bytes32 evidenceHash
    );
    event SlashingExecuted(uint64 indexed serviceId, address indexed operator, uint8 slashPercent);
    event SlashingCounterSubmitted(uint64 indexed serviceId, address indexed operator, bytes32 counterHash);
    event VerifierUpdated(address indexed oldVerifier, address indexed newVerifier);
    event SeverityCapUpdated(SlashingTypes.ViolationType indexed violation, uint256 newCap);

    constructor(address _slashingVerifier) {
        slashingVerifier = _slashingVerifier;
        for (uint8 i = 0; i < 5; i++) {
            severityCaps[i] = SlashingTypes.defaultSeverityCap(SlashingTypes.ViolationType(i));
        }
    }

    function _slashingOrigin(uint64 serviceId) internal view returns (address) {
        return slashingOrigins[serviceId];
    }

    function _slashingWindow(uint64 serviceId) internal view returns (bool useDefault, uint64 window) {
        uint64 custom = customDisputeWindows[serviceId];
        if (custom == 0) return (true, 0);
        return (false, custom);
    }

    function _disputeOrigin(uint64 serviceId) internal view returns (address) {
        return disputeOrigins[serviceId];
    }

    function _recordSlashProposed(uint64 serviceId, bytes calldata offender, uint8 slashPercent) internal {
        address operator = address(bytes20(offender));
        emit SlashingProposed(
            serviceId, operator, SlashingTypes.ViolationType.SERVICE_NOT_DELIVERED, pendingEvidence[serviceId][operator]
        );
    }

    function _recordSlashExecuted(uint64 serviceId, bytes calldata offender, uint8 slashPercent) internal {
        address operator = address(bytes20(offender));
        slashHistory[operator][serviceId] += 1;
        totalSlashes[operator] += 1;
        delete pendingEvidence[serviceId][operator];
        emit SlashingExecuted(serviceId, operator, slashPercent);
    }

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

    function submitCounterEvidence(uint64 serviceId, bytes calldata counterEvidence)
        external
        returns (bytes32 counterHash)
    {
        counterHash = keccak256(counterEvidence);
        emit SlashingCounterSubmitted(serviceId, msg.sender, counterHash);
    }

    function recommendedSeverity(SlashingTypes.ViolationType violation) external view returns (uint256) {
        return severityCaps[uint8(violation)];
    }

    function operatorReputation(address operator)
        external
        view
        returns (uint256 totalSlashes_, uint256 lastSlashPercent)
    {
        return (totalSlashes[operator], 0);
    }

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
