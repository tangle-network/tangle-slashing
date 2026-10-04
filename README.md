# Tangle Slashing

Reusable slashing conditions for all compute blueprints on Tangle Network.

**The insight**: every compute marketplace (GPUs, TPUs, inference, storage)
faces the same trust problem — "the operator claimed to provide X, did they
actually provide X?" — and the answer decomposes into the same five checkable
conditions regardless of what X is.

## The five universal violation types

| Type | What it proves | Max severity | Evidence |
|---|---|---|---|
| `SERVICE_NOT_DELIVERED` | Operator accepted payment but didn't provide the service | 5% | Attestation that the service was unreachable |
| `SERVICE_MISMATCH` | Service was provided but doesn't match what was quoted | 25% | Device identity / benchmark comparison |
| `SERVICE_UNAVAILABLE` | Service was down during the paid period | 10% | Uptime logs with timestamps |
| `ATTESTATION_INVALID` | TEE/security claim doesn't match reality | 100% (eject) | Fresh TEE report that contradicts the claim |
| `LIFECYCLE_VIOLATION` | Operator didn't maintain service lifecycle (credentials, cleanup) | 1% | Access logs past expiry, stale device state |

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    SlashingRegistry                          │
│                                                              │
│  ┌──────────┐  ┌──────────────┐  ┌─────────────────────┐   │
│  │ submit() │→ │ challenge    │→ │ execute()           │   │
│  │          │  │ period       │  │ (permissionless)    │   │
│  └──────────┘  └──────────────┘  └─────────────────────┘   │
│       │               │                    │                 │
│       ▼               ▼                    ▼                 │
│  ┌──────────────────────────────────────────────────────┐   │
│  │           IEvidenceVerifier (per blueprint)          │   │
│  │  GPU: nvidia-smi + TEE report                       │   │
│  │  Inference: model output hash                       │   │
│  │  Storage: data availability proof                   │   │
│  └──────────────────────────────────────────────────────┘   │
│                              │                                │
│                              ▼                                │
│                   ┌──────────────────┐                        │
│                   │  tnt-core        │                        │
│                   │  operator        │                        │
│                   │  staking         │                        │
│                   └──────────────────┘                        │
└──────────────────────────────────────────────────────────────┘
```

**The registry is GENERIC** (any blueprint can use it). **The verifiers are
SPECIFIC** (each blueprint registers its own evidence verification logic).

## Usage

### Blueprint side (import and register)

```solidity
import { ISlashingRegistry, SlashingTypes } from "tangle-slashing/contracts/src/ISlashingRegistry.sol";

contract MyComputeBlueprint {
    ISlashingRegistry public slashing;

    constructor(address slashingRegistry) {
        slashing = ISlashingRegistry(slashingRegistry);
        slashing.registerVerifier(blueprintId, myVerifier);
    }
}
```

### User side (accuse an operator)

```solidity
slashing.submit(
    blueprintId,
    serviceId,
    SlashingTypes.SERVICE_MISMATCH,
    abi.encode(nvidiaSmiOutput, expectedClass),
    2500 // 25% severity
);
```

### Operator side (counter with evidence)

```solidity
slashing.counter(
    claimId,
    abi.encode(accessLogs, deviceAllocationProof)
);
```

## Evidence standards

Each violation type has a standard evidence format (defined in
`SlashingTypes.sol`). The registry doesn't interpret the evidence — it
delegates to the blueprint's registered verifier. This keeps the registry
generic and the verification domain-specific.

## Severity policy

Severity caps are configurable per violation type and can be updated by
governance. Defaults are conservative (low for first offenses, maximum for
attestation fraud).

## License

MIT OR Apache-2.0
