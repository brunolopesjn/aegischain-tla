---------------------------- MODULE ConsentStateMachine ----------------------------
(********************************************************************************)
(* TLA+ Specification of the AegisChain Consent State Machine                   *)
(*                                                                              *)
(* This specification models the consent lifecycle for medical image            *)
(* sharing in the AegisChain framework. It verifies three safety                *)
(* invariants:                                                                  *)
(*   1. TypeInvariant - state variables remain within valid domains             *)
(*   2. SubjectControl - only patients can grant/revoke consent (SR3)           *)
(*   3. NonBypassableExpiry - expired consent never permits access (SR4)        *)
(*                                                                              *)
(* EXTENSION (multi-provider): Providers is now a SET, not a single constant.   *)
(* Every per-consent variable (status, stateChanger, expired, accessResult,     *)
(* expiryTime) is a FUNCTION indexed by provider, mirroring the real            *)
(* chaincode's composite key (patientID~studyUID~providerID): each provider     *)
(* has its own, fully independent consent object for the same patient/study.   *)
(* This lets TLC explore every interleaving of actions ACROSS providers, not    *)
(* just within a single provider's object, directly testing the paper's claim  *)
(* that scaling to M providers introduces no new state transitions - only      *)
(* replicated, non-interfering instances of the same verified machine.         *)
(*                                                                              *)
(* Paper: Accompanies a paper submitted to IEEE Access (double-blind review).   *)
(********************************************************************************)

EXTENDS Naturals, FiniteSets

CONSTANTS Patient, Providers

VARIABLES status,          \* status[p]: current consent state for provider p
          lastActor,       \* Last actor (Patient, some p in Providers, or "none") to perform any action
          stateChanger,    \* stateChanger[p]: actor who caused provider p's last STATE TRANSITION
          expired,         \* expired[p]: whether expiration has been triggered for provider p
          accessResult,    \* accessResult[p]: result of the last CheckAccess for provider p
          time,            \* Current time (single shared clock across all providers)
          expiryTime       \* expiryTime[p]: time at which provider p's consent expires

vars == <<status, lastActor, stateChanger, expired, accessResult, time, expiryTime>>

(***************************************************************************)
(* Valid states for the consent lifecycle                                   *)
(***************************************************************************)
States == {"NONE", "WAITING_APPROVAL", "GRANTED", "REVOKED", "EXPIRED"}

(***************************************************************************)
(* Type invariant: all variables remain within their valid domains          *)
(* Now quantified over Providers, since each is a per-provider function.    *)
(***************************************************************************)
TypeInvariant ==
    /\ status \in [Providers -> States]
    /\ lastActor \in ({Patient, "none"} \cup Providers)
    /\ stateChanger \in [Providers -> ({Patient, "none", "system"} \cup Providers)]
    /\ expired \in [Providers -> BOOLEAN]
    /\ accessResult \in [Providers -> {"PERMIT", "DENY", "PENDING"}]
    /\ time \in Nat
    /\ expiryTime \in [Providers -> Nat]

(***************************************************************************)
(* Initial state: no consent exists for any provider, no access decision   *)
(* has been made, single shared clock starts at 0.                         *)
(***************************************************************************)
Init ==
    /\ status = [p \in Providers |-> "NONE"]
    /\ lastActor = "none"
    /\ stateChanger = [p \in Providers |-> "none"]
    /\ expired = [p \in Providers |-> FALSE]
    /\ accessResult = [p \in Providers |-> "PENDING"]
    /\ time = 0
    /\ expiryTime = [p \in Providers |-> 3]  \* Every provider's consent expires at time = 3

(***************************************************************************)
(* Action: Provider p requests access to a patient's imaging study          *)
(* Transition: status[p]: NONE -> WAITING_APPROVAL                          *)
(* Guard: status[p] must be NONE                                            *)
(* Only provider p's own object is touched; every other provider's state    *)
(* is left UNCHANGED by virtue of function EXCEPT update.                   *)
(***************************************************************************)
ProviderRequestAccess(p) ==
    /\ status[p] = "NONE"
    /\ status' = [status EXCEPT ![p] = "WAITING_APPROVAL"]
    /\ lastActor' = p
    /\ stateChanger' = [stateChanger EXCEPT ![p] = p]
    /\ UNCHANGED <<expired, accessResult, time, expiryTime>>

(***************************************************************************)
(* Action: Patient approves a pending, revoked, or expired consent for      *)
(* provider p                                                               *)
(* Transition: status[p]: {WAITING_APPROVAL, REVOKED, EXPIRED} -> GRANTED   *)
(* Guard: only Patient can execute this (SR3 - Subject Control)             *)
(***************************************************************************)
PatientApprove(p) ==
    /\ status[p] \in {"WAITING_APPROVAL", "REVOKED", "EXPIRED"}
    /\ status' = [status EXCEPT ![p] = "GRANTED"]
    /\ lastActor' = Patient
    /\ stateChanger' = [stateChanger EXCEPT ![p] = Patient]
    /\ expired' = [expired EXCEPT ![p] = FALSE]
    /\ accessResult' = [accessResult EXCEPT ![p] = "PENDING"]
    /\ UNCHANGED <<time, expiryTime>>

(***************************************************************************)
(* Action: Patient denies a pending access request from provider p         *)
(* Transition: status[p]: WAITING_APPROVAL -> REVOKED                       *)
(* Guard: only Patient can execute this (SR3 - Subject Control)             *)
(***************************************************************************)
PatientDeny(p) ==
    /\ status[p] = "WAITING_APPROVAL"
    /\ status' = [status EXCEPT ![p] = "REVOKED"]
    /\ lastActor' = Patient
    /\ stateChanger' = [stateChanger EXCEPT ![p] = Patient]
    /\ UNCHANGED <<expired, accessResult, time, expiryTime>>

(***************************************************************************)
(* Action: Patient revokes an active (GRANTED) consent for provider p      *)
(* Transition: status[p]: GRANTED -> REVOKED                                *)
(* Guard: only Patient can execute this (SR3 - Subject Control)             *)
(***************************************************************************)
PatientRevoke(p) ==
    /\ status[p] = "GRANTED"
    /\ status' = [status EXCEPT ![p] = "REVOKED"]
    /\ lastActor' = Patient
    /\ stateChanger' = [stateChanger EXCEPT ![p] = Patient]
    /\ accessResult' = [accessResult EXCEPT ![p] = "DENY"]
    /\ UNCHANGED <<expired, time, expiryTime>>

(***************************************************************************)
(* Action: Provider p checks access (the core verification operation)      *)
(*                                                                         *)
(* This action implements the LAZY EXPIRATION logic (SR4) for provider p's *)
(* own object only:                                                        *)
(*   - If GRANTED and NOT expired: access is PERMITTED                     *)
(*   - If GRANTED and expired: state[p] transitions to EXPIRED atomically  *)
(*     BEFORE returning DENY (non-bypassable expiry)                       *)
(*   - Otherwise: access is DENIED                                         *)
(*                                                                         *)
(* Note: When lazy expiration triggers, stateChanger[p] is set to "system" *)
(* because the transition is automatic, not initiated by a human actor.    *)
(* Crucially, this action never reads or writes any OTHER provider's       *)
(* state[q], expired[q], etc. for q # p - the composite-key independence   *)
(* assumed by the paper is enforced structurally by this action's shape.   *)
(***************************************************************************)
ProviderCheckAccess(p) ==
    /\ lastActor' = p
    /\ IF status[p] = "GRANTED" /\ time >= expiryTime[p]
       THEN (* Lazy expiration: atomic transition before denial *)
            /\ status' = [status EXCEPT ![p] = "EXPIRED"]
            /\ stateChanger' = [stateChanger EXCEPT ![p] = "system"]
            /\ expired' = [expired EXCEPT ![p] = TRUE]
            /\ accessResult' = [accessResult EXCEPT ![p] = "DENY"]
       ELSE IF status[p] = "GRANTED" /\ time < expiryTime[p]
            THEN (* Valid consent: permit access *)
                 /\ status' = status
                 /\ stateChanger' = stateChanger  \* No state change
                 /\ expired' = [expired EXCEPT ![p] = FALSE]
                 /\ accessResult' = [accessResult EXCEPT ![p] = "PERMIT"]
            ELSE (* No valid consent: deny access *)
                 /\ status' = status
                 /\ stateChanger' = stateChanger  \* No state change
                 /\ expired' = expired
                 /\ accessResult' = [accessResult EXCEPT ![p] = "DENY"]
    /\ UNCHANGED <<time, expiryTime>>

(***************************************************************************)
(* Action: Time advances by one unit (single shared clock)                 *)
(* This models the passage of time to test expiration behavior.            *)
(*                                                                         *)
(* When time advances, EVERY provider's previous accessResult is           *)
(* invalidated, for the same reason as in the single-provider model: the   *)
(* Aegis Proxy performs a fresh CheckAccess on every request, so stale     *)
(* results are never reused, regardless of which provider is asking.       *)
(***************************************************************************)
Tick ==
    /\ time < 6  \* Bound time to keep state space finite
    /\ time' = time + 1
    /\ accessResult' = [p \in Providers |-> "PENDING"]
    /\ UNCHANGED <<status, lastActor, stateChanger, expired, expiryTime>>

(***************************************************************************)
(* Next-state relation: any provider may independently perform any of its  *)
(* actions at any step; TLC explores ALL interleavings across providers.   *)
(***************************************************************************)
Next ==
    \/ \E p \in Providers : ProviderRequestAccess(p)
    \/ \E p \in Providers : PatientApprove(p)
    \/ \E p \in Providers : PatientDeny(p)
    \/ \E p \in Providers : PatientRevoke(p)
    \/ \E p \in Providers : ProviderCheckAccess(p)
    \/ Tick

(***************************************************************************)
(* =================== SAFETY INVARIANTS ===================               *)
(* Both invariants are now universally quantified over Providers: they     *)
(* must hold independently for EVERY provider's object, in every reachable *)
(* state, under every interleaving - this is the empirical test of the     *)
(* "independent replicated instances" claim.                               *)
(***************************************************************************)

(***************************************************************************)
(* Invariant 1: SubjectControl (SR3)                                       *)
(*                                                                         *)
(* For every provider p, if p's consent status is GRANTED or REVOKED,      *)
(* then the actor who caused that transition must have been the Patient.   *)
(*                                                                         *)
(* This corresponds to Algorithm 2 (line 6) in the paper: the invokerID   *)
(* must match the ownerInvokerID. A provider can invoke CheckAccess        *)
(* (which reads state) but cannot cause transitions to GRANTED/REVOKED,    *)
(* for its own object OR for any other provider's object.                  *)
(***************************************************************************)
SubjectControl ==
    \A p \in Providers :
        /\ (status[p] = "GRANTED") => (stateChanger[p] = Patient)
        /\ (status[p] = "REVOKED") => (stateChanger[p] = Patient)

(***************************************************************************)
(* Invariant 2: NonBypassableExpiry (SR4)                                  *)
(*                                                                         *)
(* For every provider p, it must NEVER be the case that:                   *)
(*   - p's consent status is GRANTED, AND                                  *)
(*   - the current (shared) time has exceeded p's expiry threshold, AND    *)
(*   - p's access result is PERMIT                                         *)
(*                                                                         *)
(* This ensures the lazy expiration logic correctly transitions each       *)
(* provider's state to EXPIRED before returning any access decision,       *)
(* independently of what any other provider is doing concurrently.         *)
(***************************************************************************)
NonBypassableExpiry ==
    \A p \in Providers :
        ~(status[p] = "GRANTED" /\ time >= expiryTime[p] /\ accessResult[p] = "PERMIT")

(***************************************************************************)
(* Temporal specification                                                  *)
(***************************************************************************)
Spec == Init /\ [][Next]_vars

===================================================================================
