# Tangle Slashing

Evidence admission for TNT's native proposal, dispute and staking lifecycle.
[`SlashingTypes`](contracts/src/SlashingTypes.sol) owns violation severity caps.

## Collector evidence

Deploy `GpuLeaseEvidenceVerifier(initialCollector)`. Its deployer manages the
collector set with `setCollector`; revocation rejects that key's signatures.
Collector signatures retain the EIP-712 domain `GpuLeaseEvidenceVerifier`, version
`1`, chain ID and verifier address, with this unchanged type:

`Evidence(uint8 violation,uint8 kind,uint64 timestamp,address collector,bytes32 payloadHash,bytes32 serviceId,address operator)`

Sign `evidenceDigest` using the raw payload, then wrap it as
`abi.encode(rawPayload, signature)` in `EvidenceEnvelope.payload`. Signatures are
canonical 65-byte `(r,s,v)` with `v` equal to 27 or 28. Zero/future timestamps fail authentication.
For native submission, the envelope's `serviceId` is the manager's
`evidenceContext(nativeServiceId)`, binding core, manager and native ID.

`ComputeProviderSlashing.submitEvidence` verifies before locking a pending hash
and calling TNT's nonpayable `proposeSlash` with the verdict in basis points.
Native failure rolls back admission. Pending evidence cannot be replaced;
consumed hashes cannot be replayed after execution. The constructor and existing
consumer hook helpers remain; duplicate policy/reputation state is retired in
favor of TNT. A manager exposes its existing `tangleCore()` getter.

Collector endorsement alone does not prove an invalid operator attestation.
`ATTESTATION_INVALID` remains unsupported until an authenticated report-verification
contract is available; matching-device and opaque payloads cannot claim its cap.

## Checks

Run `forge soldeer install && forge test`. Native TNT integration is proved by the
separate pinned test project in the owning TNT repository.

## License

MIT OR Apache-2.0
