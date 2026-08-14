# AegisChain Consent State Machine — TLA+ Formal Verification

This repository contains the TLA+ specification and model checking configuration for the **consent state machine** of the AegisChain framework. The specification formally verifies that the consent lifecycle cannot reach an inconsistent state under any interleaving of patient and provider actions.

## Paper

This specification accompanies a paper submitted to IEEE Access 2026 (under double-blind review).

## Overview

AegisChain uses a deterministic state machine to govern the consent lifecycle for medical image sharing. The state machine has four states:

```
NONE → WAITING_APPROVAL → GRANTED → REVOKED
                                  ↓
                               EXPIRED
```

A key design feature is **lazy expiration**: instead of using background processes to prune expired consents, the system evaluates the expiry timestamp on-the-fly during access verification (`CheckAccess`). If the consent has expired, the state is atomically transitioned to `EXPIRED` before access is denied.

## Verified Invariants

The TLC model checker exhaustively explores all reachable states and verifies three safety invariants:

| Invariant | Requirement | Description |
|-----------|-------------|-------------|
| `TypeInvariant` | — | All state variables remain within their valid domains |
| `SubjectControl` | SR3 | Only the patient can cause transitions to `GRANTED` or `REVOKED` |
| `NonBypassableExpiry` | SR4 | No state exists where consent is `GRANTED`, time has exceeded expiry, and access is `PERMIT` |

## Verification Results

TLC exhaustively explored the full reachable state space and confirmed that **no invariant violations exist**. The results are summarized below.

| Metric | Value |
|--------|-------|
| States generated | 254 |
| Distinct states found | 84 |
| State graph depth | 10 |
| Invariants verified | 3 (TypeInvariant, SubjectControl, NonBypassableExpiry) |
| Violations found | **0** |
| Verification time | < 1 s |

### Full TLC Output

```
$ java -jar tla2tools.jar -config ConsentStateMachine.cfg ConsentStateMachine.tla

TLC2 Version 2026.04.09.014118 (rev: 389440f)
Running breadth-first search Model-Checking with fp 1 and seed 7981246176005043626
with 1 worker on 16 cores with 8004MB heap and 64MB offheap memory
(Linux 6.19.10-zen1-1-zen amd64, Arch Linux 21.0.10 64bit, MSBDiskFPSet, DiskStateQueue).

Starting... (2026-04-11 20:49:26)
Computing initial states...
Finished computing initial states: 1 distinct state generated at 2026-04-11 20:49:26.
Model checking completed. No error has been found.
  Estimates of the probability that TLC did not check all reachable states
  because two distinct states had the same fingerprint:
  calculated (optimistic):  val = 7.7E-16
254 states generated, 84 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 10.
The average outdegree of the complete state graph is 1 (minimum is 0, the maximum 4
and the 95th percentile is 3).
Finished in 00s at (2026-04-11 20:49:26)
```

### Environment

| Component | Version |
|-----------|---------|
| TLC | 2026.04.09.014118 (rev: 389440f) |
| Java | OpenJDK 21.0.10 |
| OS | Arch Linux, kernel 6.19.10-zen1-1-zen (amd64) |

## Files

| File | Description |
|------|-------------|
| `ConsentStateMachine.tla` | TLA+ specification of the consent state machine |
| `ConsentStateMachine.cfg` | TLC model checker configuration |
| `README.md` | This file |

## How to Reproduce

### Prerequisites

- Java Runtime Environment (JRE) 11 or higher
- TLC model checker (`tla2tools.jar`)

### Option 1: Command Line (Recommended)

```bash
# Download TLC
wget https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar

# Run the model checker
java -jar tla2tools.jar -config ConsentStateMachine.cfg ConsentStateMachine.tla
```

### Option 2: TLA+ Toolbox (GUI)

1. Download and install the [TLA+ Toolbox](https://lamport.azurewebsites.net/tla/toolbox.html)
2. Open `ConsentStateMachine.tla` in the Toolbox
3. Create a new model:
   - **Specification**: `Spec`
   - **Constants**: Assign `Patient` and `Provider` as model values
   - **Invariants**: Add `TypeInvariant`, `SubjectControl`, and `NonBypassableExpiry`
4. Click **Run TLC** — verification completes in under 1 second

## State Space

The specification bounds time to `[0, 6]` with an expiry time of `3`, resulting in a finite and tractable state space of 84 distinct states. The model checker explores all possible interleavings of:

- `ProviderRequestAccess` — Provider requests access (NONE → WAITING_APPROVAL)
- `PatientApprove` — Patient grants consent with expiry ({WAITING_APPROVAL, REVOKED, EXPIRED} → GRANTED)
- `PatientDeny` — Patient denies a pending request (WAITING_APPROVAL → REVOKED)
- `PatientRevoke` — Patient revokes active consent (GRANTED → REVOKED)
- `ProviderCheckAccess` — Provider checks access, with lazy expiration logic (may trigger GRANTED → EXPIRED)
- `Tick` — Time advances, invalidating stale access results

### Key Modeling Decisions

1. **`stateChanger` vs. `lastActor`**: The specification distinguishes between the actor who last performed any action (`lastActor`) and the actor who caused the last state transition (`stateChanger`). This separation is necessary because `CheckAccess` is a read operation that may update `lastActor` to `Provider` without changing the consent state. The `SubjectControl` invariant checks `stateChanger`, not `lastActor`.

2. **`accessResult` reset on `Tick`**: When time advances, `accessResult` is reset to `"PENDING"` because stale access decisions are not reused in the real system — the Aegis Proxy performs a fresh `CheckAccess` on every DICOMweb request.

3. **Lazy expiration as `"system"`**: When `CheckAccess` triggers expiration, `stateChanger` is set to `"system"` rather than `Provider`, because the state transition is an automatic consequence of time passage, not a deliberate provider action.

## Correspondence to the Paper

| TLA+ Action | Consent Contract Function |
|-------------|---------------------------|
| `PatientApprove` | `UpdateConsentStatus()` (Approve=true) |
| `PatientDeny` | `UpdateConsentStatus()` (Approve=false) |
| `PatientRevoke` | `UpdateConsentStatus()` (Approve=false) |
| `ProviderCheckAccess` | `CheckAccess()` |
| `ProviderRequestAccess` | `RequestAccess()` |

| TLA+ Invariant | Requirement |
|----------------|-------------|
| `TypeInvariant` | — |
| `SubjectControl` | SR3 (Subject Control) |
| `NonBypassableExpiry` | SR4 (Non-Bypassable Expiration) |

## License

This specification is released under the [MIT License](LICENSE).
