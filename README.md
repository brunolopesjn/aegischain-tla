# AegisChain Consent State Machine — TLA+ Formal Verification

This repository contains the TLA+ specification and model checking configuration for the **consent state machine** of the AegisChain framework. The specification formally verifies that the consent lifecycle cannot reach an inconsistent state under any interleaving of patient and provider actions — including interleavings **across multiple concurrent providers** for the same patient.

## Paper

This specification accompanies a paper submitted to IEEE Access (under double-blind review).

## Overview

AegisChain uses a deterministic state machine to govern the consent lifecycle for medical image sharing. Each `(patient, study, provider)` triple has its own independent consent object, mirroring the chaincode's real composite key (`patientID~studyUID~providerID`). Each object's state machine has four states:

```
NONE → WAITING_APPROVAL → GRANTED → REVOKED
                                  ↓
                               EXPIRED
```

A key design feature is **lazy expiration**: instead of using background processes to prune expired consents, the system evaluates the expiry timestamp on-the-fly during access verification (`CheckAccess`). If the consent has expired, the state is atomically transitioned to `EXPIRED` before access is denied.

**Multi-provider extension.** The specification models `Providers` as a *set* (not a single constant): every per-consent variable (`status`, `stateChanger`, `expired`, `accessResult`, `expiryTime`) is a function indexed by provider identity. This lets TLC explore arbitrary interleavings of actions across different providers requesting or holding access to the same patient's study, directly testing the claim — made architecturally in the paper on the basis of the chaincode's composite-key design — that different providers' consent objects are fully independent and cannot interfere with one another. Setting `Providers` to a single-element set recovers the original single-provider model and its 254/84-state result exactly.

## Verified Invariants

The TLC model checker exhaustively explores all reachable states and verifies three safety invariants, each now universally quantified over every provider in `Providers`:

| Invariant | Requirement | Description |
|-----------|-------------|-------------|
| `TypeInvariant` | — | All state variables remain within their valid domains for every provider |
| `SubjectControl` | SR3 | For every provider, only the patient can cause transitions to `GRANTED` or `REVOKED` of that provider's consent object |
| `NonBypassableExpiry` | SR4 | For every provider, no state exists where consent is `GRANTED`, time has exceeded expiry, and access is `PERMIT` |

## Verification Results

TLC exhaustively explored the full reachable state space under both configurations and confirmed that **no invariant violations exist** in either.

| Metric | Single-provider (`Providers = {p1}`) | Two-provider (`Providers = {p1, p2}`) |
|--------|--------------------------------------|-----------------------------------------|
| States generated | 254 | 5,699 |
| Distinct states found | 84 | 1,074 |
| State graph depth | 10 | 13 |
| Invariants verified | 3 (`TypeInvariant`, `SubjectControl`, `NonBypassableExpiry`) | 3 (same, universally quantified over `Providers`) |
| Violations found | **0** | **0** |
| Verification time | < 1 s | < 1 s |

The two-provider configuration is the one shipped in `ConsentStateMachine.cfg`. To reproduce the single-provider result, edit the `Providers` assignment in the config to a singleton set (see [How to Reproduce](#how-to-reproduce)).

### Full TLC Output (two-provider configuration)

```
$ java -jar tla2tools.jar -config ConsentStateMachine.cfg ConsentStateMachine.tla

TLC2 Version 2026.04.09.014118 (rev: 389440f)
Running breadth-first search Model-Checking with fp 102 and seed 2842965710116362053
with 1 worker on 16 cores with 8004MB heap and 64MB offheap memory
(Linux 7.0.14-arch1-1 amd64, Arch Linux 21.0.11 64bit, MSBDiskFPSet, DiskStateQueue).

Starting... (2026-07-24 16:08:14)
Computing initial states...
Finished computing initial states: 1 distinct state generated at 2026-07-24 16:08:14.
Model checking completed. No error has been found.
  Estimates of the probability that TLC did not check all reachable states
  because two distinct states had the same fingerprint:
  calculated (optimistic):  val = 2.7E-13
5699 states generated, 1074 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 13.
The average outdegree of the complete state graph is 1 (minimum is 0, the maximum 7
and the 95th percentile is 4).
Finished in 00s at (2026-07-24 16:08:14)
```

### Environment

| Component | Version |
|-----------|---------|
| TLC | 2026.04.09.014118 (rev: 389440f) |
| Java | OpenJDK 21.0.11 |
| OS | Arch Linux, kernel 7.0.14-arch1-1 (amd64) |

## Files

| File | Description |
|------|-------------|
| `ConsentStateMachine.tla` | TLA+ specification of the multi-provider consent state machine |
| `ConsentStateMachine.cfg` | TLC model checker configuration (two-provider: `Providers = {p1, p2}`) |
| `README.md` | This file |

## How to Reproduce

### Prerequisites

- Java Runtime Environment (JRE) 11 or higher
- TLC model checker (`tla2tools.jar`)

### Option 1: Command Line (Recommended)

```bash
# Download TLC
wget https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar

# Run the model checker (two-provider configuration, as shipped)
java -jar tla2tools.jar -config ConsentStateMachine.cfg ConsentStateMachine.tla
```

To reproduce the single-provider result (254 states, 84 distinct), edit `ConsentStateMachine.cfg` and reduce the `Providers` assignment to a single model value, e.g.:

```
CONSTANTS
    Patient = Patient
    p1 = p1
    Providers = {p1}
```

### Option 2: TLA+ Toolbox (GUI)

1. Download and install the [TLA+ Toolbox](https://lamport.azurewebsites.net/tla/toolbox.html)
2. Open `ConsentStateMachine.tla` in the Toolbox
3. Create a new model:
   - **Specification**: `Spec`
   - **Constants**: Assign `Patient` as a model value; assign `Providers` as a *set* of model values (e.g., `{p1, p2}`)
   - **Invariants**: Add `TypeInvariant`, `SubjectControl`, and `NonBypassableExpiry`
4. Click **Run TLC** — verification completes in under 1 second for either configuration

## State Space

The specification bounds time to `[0, 6]` with an expiry time of `3` for every provider, resulting in a finite and tractable state space. The model checker explores all possible interleavings, across every provider in `Providers`, of:

- `ProviderRequestAccess(p)` — Provider `p` requests access (`status[p]`: NONE → WAITING_APPROVAL)
- `PatientApprove(p)` — Patient grants `p`'s consent with expiry (`status[p]`: {WAITING_APPROVAL, REVOKED, EXPIRED} → GRANTED)
- `PatientDeny(p)` — Patient denies `p`'s pending request (`status[p]`: WAITING_APPROVAL → REVOKED)
- `PatientRevoke(p)` — Patient revokes `p`'s active consent (`status[p]`: GRANTED → REVOKED)
- `ProviderCheckAccess(p)` — Provider `p` checks access, with lazy expiration logic (may trigger `status[p]`: GRANTED → EXPIRED)
- `Tick` — Time advances (single shared clock across all providers), invalidating every provider's stale access result

Each action operates on exactly one provider's object at a time (chosen non-deterministically by TLC via `\E p \in Providers`), and by construction never reads or writes any other provider's state — mirroring the composite-key isolation of the real chaincode.

### Key Modeling Decisions

1. **`Providers` as a set, per-consent variables as functions**: `status`, `stateChanger`, `expired`, `accessResult`, and `expiryTime` are all functions of type `[Providers -> ...]` rather than scalars. This is the core extension over the original single-provider model and is what allows TLC to explore genuine cross-provider interleavings rather than verifying one isolated object.

2. **`stateChanger` vs. `lastActor`**: The specification distinguishes between the actor who last performed any action (`lastActor`, a single global value) and the actor who caused the last state transition of a *specific provider's* object (`stateChanger[p]`). This separation is necessary because `CheckAccess` is a read-mostly operation that may update `lastActor` without changing that provider's consent state. The `SubjectControl` invariant checks `stateChanger[p]`, not `lastActor`.

3. **`accessResult` reset on `Tick`**: When time advances, `accessResult[p]` is reset to `"PENDING"` for every provider, because stale access decisions are not reused in the real system — the Aegis Proxy performs a fresh `CheckAccess` on every DICOMweb request, regardless of which provider is asking.

4. **Lazy expiration as `"system"`**: When `CheckAccess(p)` triggers expiration, `stateChanger[p]` is set to `"system"` rather than `p`, because the state transition is an automatic consequence of time passage, not a deliberate provider action.

5. **Single shared clock**: `time` remains a single scalar shared by all providers, rather than per-provider — this matches the real system, where a single wall clock governs expiry checks regardless of which provider is being evaluated.

## Correspondence to the Paper

| TLA+ Action | Consent Contract Function |
|-------------|---------------------------|
| `PatientApprove(p)` | `UpdateConsentStatus()` (Approve=true) |
| `PatientDeny(p)` | `UpdateConsentStatus()` (Approve=false) |
| `PatientRevoke(p)` | `UpdateConsentStatus()` (Approve=false) |
| `ProviderCheckAccess(p)` | `CheckAccess()` |
| `ProviderRequestAccess(p)` | `RequestAccess()` |

| TLA+ Invariant | Requirement |
|----------------|-------------|
| `TypeInvariant` | — |
| `SubjectControl` | SR3 (Subject Control) |
| `NonBypassableExpiry` | SR4 (Non-Bypassable Expiration) |

## Scope and Limitations

This specification verifies the consent state machine in isolation. It does **not** model:

- Fabric-level concurrency (e.g., MVCC conflicts) or network failures, which are handled by Fabric's own validation pipeline.
- The internal correctness of cross-chaincode invocations (`InvokeChaincode` calls to the Ownership and Logging contracts) — these are treated as atomic, always-correct primitives within the verified model.
- Concurrent *patients* — the multi-provider extension tests concurrency across providers for a single patient; scaling to multiple concurrent patients follows the same architectural independence argument (disjoint composite keys) but has not yet been subjected to the same empirical multi-actor TLC verification.

See the accompanying paper's Discussion section for a categorization of real defects found during implementation, mapped to which of these verification layers (if any) would have caught them.

## License

This specification is released under the [MIT License](LICENSE).
