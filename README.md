# Tangle Slashing

Evidence verification + BSM hooks for tnt-core's native slashing system.

**NOT a parallel slashing registry.** tnt-core already has the full lifecycle
(proposeSlash → disputeSlash → executeSlash, with bonds, admin roles,
commitment tracking, batch execution). This package provides what tnt-core
deliberately leaves to blueprints:

1. **Evidence verifiers** — domain-specific logic that interprets evidence
   (GPU identity, model output, storage proof) and recommends severity
2. **BSM hooks** — the `IBlueprintServiceManager` slashing hooks that let
   compute blueprints customize tnt-core's slashing for their domain
3. **Shared types** — the five universal violation types and evidence
   envelope format, so blueprints and verifiers speak the same language

## The five universal violation types

Every compute marketplace faces the same trust question: "did the operator
deliver what they promised?" These five types cover all the ways the answer
can be "no":

| Type | What it catches | Severity cap |
|---|---|---|
| SERVICE_NOT_DELIVERED | Accepted payment, no service | 5% |
| SERVICE_MISMATCH | Wrong GPU class, wrong model, degraded service | 25% |
| SERVICE_UNAVAILABLE | Downtime during paid period | 10% |
| ATTESTATION_INVALID | TEE/security claim doesn't match reality | 100% (eject) |
| LIFECYCLE_VIOLATION | Credentials not revoked, devices not freed | 1% |

## How it plugs into tnt-core

```
User (lessee) experiences bad service
  │
  ├─ Collects evidence (nvidia-smi, benchmark, uptime log)
  │
  ├─ Calls tnt-core: proposeSlash(serviceId, operator, slashBps, evidenceHash)
  │    └─ tnt-core calls BSM.querySlashingOrigin(serviceId)
  │         └─ SlashingHooks returns the authorized proposer
  │
  ├─ tnt-core opens the dispute window
  │    └─ tnt-core calls BSM.getSlashingWindow(serviceId)
  │         └─ SlashingHooks returns custom or default window
  │    └─ tnt-core calls BSM.onUnappliedSlash(serviceId, operator, percent)
  │         └─ SlashingHooks records the proposal
  │
  ├─ Operator disputes (posts bond): disputeSlash(slashId, reason)
  │    └─ tnt-core calls BSM.queryDisputeOrigin(serviceId)
  │         └─ SlashingHooks returns the designated arbiter (or 0)
  │
  └─ After window: executeSlash(slashId)
       └─ tnt-core calls BSM.onSlash(serviceId, operator, percent)
            └─ SlashingHooks records the outcome
```

**The evidence verification happens OFF-CHAIN** — the proposer submits the
evidence hash on-chain (as `evidence` in `proposeSlash`), and the verifier
contract (registered per-blueprint) provides a view function that governance
or the dispute resolver can call to assess the evidence.

## Usage

### Inherit the hooks in your blueprint's BSM

```solidity
import { SlashingHooks } from "tangle-slashing/contracts/src/SlashingHooks.sol";

contract GpuLeaseBlueprint is SlashingHooks {
    constructor(address verifier) SlashingHooks(verifier) {}

    // Let the lessee propose slashes:
    function setSlashingOrigin(uint64 serviceId, address origin) external override onlyOwner {
        slashingOrigins[serviceId] = origin;
    }
}
```

### Register your domain verifier

```solidity
GpuLeaseEvidenceVerifier verifier = new GpuLeaseEvidenceVerifier();
GpuLeaseBlueprint bsm = new GpuLeaseBlueprint(address(verifier));
```

## License

MIT OR Apache-2.0
