// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SlashingTypes} from "./SlashingTypes.sol";

interface IEvidenceVerifier {
    function verify(SlashingTypes.ViolationType violation, bytes calldata evidence, bytes32 serviceId, address operator)
        external
        view
        returns (bool valid, uint256 adjustedSeverityBps, string memory description);
}
