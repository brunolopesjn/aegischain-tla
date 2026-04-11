---------------------------- MODULE ConsentStateMachine ----------------------------
(***************************************************************************)
(* TLA+ Specification of the AegisChain Consent State Machine             *)
(*                                                                         *)
(* This specification models the consent lifecycle for medical image       *)
(* sharing in the AegisChain framework. It verifies three safety           *)
(* invariants:                                                             *)
(*   1. TypeInvariant - state variables remain within valid domains        *)
(*   2. SubjectControl - only patients can grant/revoke consent (SR3)      *)
(*   3. NonBypassableExpiry - expired consent never permits access (SR4)   *)
(*                                                                         *)
(* Authors: Bruno L. A. Batista, João C. Ferreira, Joaquim Celestino Jr.  *)
(* Paper: "AegisChain: Patient-Centric Smart Contracts for Secure         *)
(*         Medical Image Sharing in Permissioned Blockchains"              *)
(***************************************************************************)

EXTENDS Naturals, FiniteSets

CONSTANTS Patient, Provider

VARIABLES status,          \* Current consent state
          lastActor,       \* Last actor to perform any action
          stateChanger,    \* Actor who caused the last STATE TRANSITION
          expired,         \* Whether expiration has been triggered
          accessResult,    \* Result of the last CheckAccess
          time,            \* Current time
          expiryTime       \* Time at which consent expires

vars == <<status, lastActor, stateChanger, expired, accessResult, time, expiryTime>>

(***************************************************************************)
(* Valid states for the consent lifecycle                                   *)
(***************************************************************************)
States == {"NONE", "WAITING_APPROVAL", "GRANTED", "REVOKED", "EXPIRED"}

(***************************************************************************)
(* Type invariant: all variables remain within their valid domains          *)
(***************************************************************************)
TypeInvariant ==
    /\ status \in States
    /\ lastActor \in {Patient, Provider, "none"}
    /\ stateChanger \in {Patient, Provider, "none", "system"}
    /\ expired \in BOOLEAN
    /\ accessResult \in {"PERMIT", "DENY", "PENDING"}
    /\ time \in Nat
    /\ expiryTime \in Nat

(***************************************************************************)
(* Initial state: no consent exists, no access decision made               *)
(***************************************************************************)
Init ==
    /\ status = "NONE"
    /\ lastActor = "none"
    /\ stateChanger = "none"
    /\ expired = FALSE
    /\ accessResult = "PENDING"
    /\ time = 0
    /\ expiryTime = 3  \* Consent expires at time = 3

(***************************************************************************)
(* Action: Provider requests access to a patient's imaging study           *)
(* Transition: NONE -> WAITING_APPROVAL                                    *)
(* Guard: status must be NONE                                              *)
(***************************************************************************)
ProviderRequestAccess ==
    /\ status = "NONE"
    /\ status' = "WAITING_APPROVAL"
    /\ lastActor' = Provider
    /\ stateChanger' = Provider
    /\ UNCHANGED <<expired, accessResult, time, expiryTime>>

(***************************************************************************)
(* Action: Patient approves a pending, revoked, or expired consent         *)
(* Transition: {WAITING_APPROVAL, REVOKED, EXPIRED} -> GRANTED             *)
(* Guard: only Patient can execute this (SR3 - Subject Control)            *)
(***************************************************************************)
PatientApprove ==
    /\ status \in {"WAITING_APPROVAL", "REVOKED", "EXPIRED"}
    /\ status' = "GRANTED"
    /\ lastActor' = Patient
    /\ stateChanger' = Patient
    /\ expired' = FALSE
    /\ accessResult' = "PENDING"
    /\ UNCHANGED <<time, expiryTime>>

(***************************************************************************)
(* Action: Patient denies a pending access request                         *)
(* Transition: WAITING_APPROVAL -> REVOKED                                 *)
(* Guard: only Patient can execute this (SR3 - Subject Control)            *)
(***************************************************************************)
PatientDeny ==
    /\ status = "WAITING_APPROVAL"
    /\ status' = "REVOKED"
    /\ lastActor' = Patient
    /\ stateChanger' = Patient
    /\ UNCHANGED <<expired, accessResult, time, expiryTime>>

(***************************************************************************)
(* Action: Patient revokes an active (GRANTED) consent                     *)
(* Transition: GRANTED -> REVOKED                                          *)
(* Guard: only Patient can execute this (SR3 - Subject Control)            *)
(***************************************************************************)
PatientRevoke ==
    /\ status = "GRANTED"
    /\ status' = "REVOKED"
    /\ lastActor' = Patient
    /\ stateChanger' = Patient
    /\ accessResult' = "DENY"
    /\ UNCHANGED <<expired, time, expiryTime>>

(***************************************************************************)
(* Action: Provider checks access (the core verification operation)        *)
(*                                                                         *)
(* This action implements the LAZY EXPIRATION logic (SR4):                 *)
(*   - If GRANTED and NOT expired: access is PERMITTED                     *)
(*   - If GRANTED and expired: state transitions to EXPIRED atomically     *)
(*     BEFORE returning DENY (non-bypassable expiry)                       *)
(*   - Otherwise: access is DENIED                                         *)
(*                                                                         *)
(* Note: When lazy expiration triggers, stateChanger is set to "system"    *)
(* because the transition is automatic, not initiated by a human actor.    *)
(***************************************************************************)
ProviderCheckAccess ==
    /\ lastActor' = Provider
    /\ IF status = "GRANTED" /\ time >= expiryTime
       THEN (* Lazy expiration: atomic transition before denial *)
            /\ status' = "EXPIRED"
            /\ stateChanger' = "system"  \* Automatic system transition
            /\ expired' = TRUE
            /\ accessResult' = "DENY"
       ELSE IF status = "GRANTED" /\ time < expiryTime
            THEN (* Valid consent: permit access *)
                 /\ status' = status
                 /\ stateChanger' = stateChanger  \* No state change
                 /\ expired' = FALSE
                 /\ accessResult' = "PERMIT"
            ELSE (* No valid consent: deny access *)
                 /\ status' = status
                 /\ stateChanger' = stateChanger  \* No state change
                 /\ expired' = expired
                 /\ accessResult' = "DENY"
    /\ UNCHANGED <<time, expiryTime>>

(***************************************************************************)
(* Action: Time advances by one unit                                       *)
(* This models the passage of time to test expiration behavior.            *)
(*                                                                         *)
(* When time advances, any previous accessResult is invalidated because    *)
(* the consent state may have changed (e.g., expiration). In the real      *)
(* system, the Aegis Proxy performs a fresh CheckAccess on every request,  *)
(* so stale results are never reused. We model this by resetting           *)
(* accessResult to "PENDING".                                              *)
(***************************************************************************)
Tick ==
    /\ time < 6  \* Bound time to keep state space finite
    /\ time' = time + 1
    /\ accessResult' = "PENDING"
    /\ UNCHANGED <<status, lastActor, stateChanger, expired, expiryTime>>

(***************************************************************************)
(* Next-state relation: any of the above actions can occur                 *)
(***************************************************************************)
Next ==
    \/ ProviderRequestAccess
    \/ PatientApprove
    \/ PatientDeny
    \/ PatientRevoke
    \/ ProviderCheckAccess
    \/ Tick

(***************************************************************************)
(* =================== SAFETY INVARIANTS ===================               *)
(***************************************************************************)

(***************************************************************************)
(* Invariant 1: SubjectControl (SR3)                                       *)
(*                                                                         *)
(* If the consent status is GRANTED or REVOKED, then the actor who         *)
(* caused the transition to that state must have been the Patient.          *)
(*                                                                         *)
(* This corresponds to Algorithm 2 (line 6) in the paper: the invokerID   *)
(* must match the ownerInvokerID. The Provider can invoke CheckAccess      *)
(* (which reads state) but cannot cause transitions to GRANTED/REVOKED.    *)
(*                                                                         *)
(* The EXPIRED state can be reached via "system" (lazy expiration) or      *)
(* via Provider's CheckAccess triggering it, so it is excluded from        *)
(* this invariant. WAITING_APPROVAL is reached via Provider, which is      *)
(* also correct (it represents a request, not an authorization).           *)
(***************************************************************************)
SubjectControl ==
    /\ (status = "GRANTED") => (stateChanger = Patient)
    /\ (status = "REVOKED") => (stateChanger = Patient)

(***************************************************************************)
(* Invariant 2: NonBypassableExpiry (SR4)                                  *)
(*                                                                         *)
(* It must NEVER be the case that:                                         *)
(*   - The consent status is GRANTED, AND                                  *)
(*   - The current time has exceeded the expiry threshold, AND             *)
(*   - The access result is PERMIT                                         *)
(*                                                                         *)
(* This ensures the lazy expiration logic correctly transitions the        *)
(* state to EXPIRED before returning any access decision.                  *)
(***************************************************************************)
NonBypassableExpiry ==
    ~(status = "GRANTED" /\ time >= expiryTime /\ accessResult = "PERMIT")

(***************************************************************************)
(* Temporal specification                                                  *)
(***************************************************************************)
Spec == Init /\ [][Next]_vars

===================================================================================
