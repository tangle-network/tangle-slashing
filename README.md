# Tangle Slashing

Domain evidence verification and Blueprint Service Manager helpers for tnt-core's
native slashing lifecycle. tnt-core owns proposal bonds, disputes, execution,
and staking; this package supplies the evidence verdict and hook helpers.

| Violation | Maximum severity |
|---|---|
| `SERVICE_NOT_DELIVERED` | 5% |
| `SERVICE_MISMATCH` | 25% |
| `SERVICE_UNAVAILABLE` | 10% |
| `ATTESTATION_INVALID` | 100% |
| `LIFECYCLE_VIOLATION` | 1% |

## GPU collector signatures

Deploy `new GpuLeaseEvidenceVerifier(trustedCollector)` with a nonzero collector
address whose measurements your blueprint trusts. Changing collectors requires
a new verifier; inherited BSM administration can select that verifier.

The existing `SlashingTypes.EvidenceEnvelope` ABI is retained. To submit evidence:

1. Populate the envelope with its evidence kind, collection timestamp, designated
   collector, and **raw** domain payload.
2. Obtain `evidenceDigest(violation, envelope, serviceId, operator)` and sign that
   EIP-712 digest with the collector's key. The type is
   `Evidence(uint8 violation,uint8 kind,uint64 timestamp,address collector,bytes32 payloadHash,bytes32 serviceId,address operator)`.
3. Replace `envelope.payload` with `abi.encode(rawPayload, signature)` and pass
   `abi.encode(envelope)` to `verify` through `IEvidenceVerifier`.

The domain is `GpuLeaseEvidenceVerifier`, version `1`, with the current chain id
and verifier address. Signatures are canonical 65-byte secp256k1 `(r,s,v)` with
`v` equal to 27 or 28. Every verdict authenticates the configured collector;
unsigned legacy envelopes cannot support slashing. Zero or future timestamps
are rejected. The collector attests that the signed event happened during the
paid service period; this reference contract cannot independently observe a GPU
or look up a lease's period.

Counter-evidence uses the same payload wrapper and `counterDigest(claimId,
envelope)`, with the type
`CounterEvidence(bytes32 claimId,uint8 kind,uint64 timestamp,address collector,bytes32 payloadHash)`.
It is bound to that claim and domain, and remains an input to governance review.
A verdict is a stateless assessment: replay within the same claim is handled by
tnt-core's slashing lifecycle, not by this view contract.

`ComputeProviderSlashing` provides internal origin, window, recording and admin
helpers for a BSM to connect to tnt-core. Its `submitEvidence` records a hash;
it does not execute a slash or validate an envelope. Governance or the dispute
resolver calls the registered verifier before assessing a claim.

## Checks

```sh
forge soldeer install
forge test
```

## License

MIT OR Apache-2.0
