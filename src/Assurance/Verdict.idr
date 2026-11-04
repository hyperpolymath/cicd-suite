-- SPDX-License-Identifier: MPL-2.0
module Assurance.Verdict

%default total

||| Required checks, conditionally required checks and non-blocking signals.
public export
data Obligation = Mandatory | Conditional | Advisory

||| ExemptValidated is a claim from a trusted policy evaluator, not a string
||| that an external JSON document may create by naming the constructor.
public export
data Applicability = Applies | ExemptValidated | Undetermined

||| In particular, skipped/cancelled/never-started are not success.
public export
data Execution
  = CompletedSuccess | CompletedFailure | Skipped | Cancelled
  | NeverStarted | StillRunning

||| A receipt from any other revision must not discharge a current obligation.
public export
data Revision = CurrentRevision | PreviousRevision | RevisionUnknown

||| AdmissionVerified means a separate trusted adapter checked origin, binding,
||| tool invocation and non-revocation. The kernel does NOT establish those facts.
public export
data Admission = AdmissionVerified | AdmissionUnverified | AdmissionRevoked

public export
record Observation where
  constructor MkObservation
  obligation    : Obligation
  applicability : Applicability
  execution     : Execution
  revision      : Revision
  admission     : Admission

public export
data Verdict = Passed | Blocked

||| True for an applicable mandatory or conditional observation, regardless of
||| its execution, revision or admission state.
public export
isRequired : Observation -> Bool
isRequired (MkObservation Mandatory Applies _ _ _) = True
isRequired (MkObservation Conditional Applies _ _ _) = True
isRequired _ = False

||| A validated exemption is non-applicable, not successful execution, and is
||| acceptable regardless of the other fields. An applicable advisory observation
||| requires a terminal success or failure on the current revision and verified
||| admission. Other applicable observations require successful execution on the
||| current revision and verified admission.
||| Undetermined applicability is not acceptable.
public export
acceptable : Observation -> Bool
acceptable (MkObservation Advisory Applies CompletedSuccess CurrentRevision AdmissionVerified) = True
acceptable (MkObservation Advisory Applies CompletedFailure CurrentRevision AdmissionVerified) = True
acceptable (MkObservation _ ExemptValidated _ _ _) = True
acceptable (MkObservation _ Applies CompletedSuccess CurrentRevision AdmissionVerified) = True
acceptable _ = False

||| True when at least one observation is applicable and mandatory or conditional.
public export
hasRequired : List Observation -> Bool
hasRequired [] = False
hasRequired (x :: xs) = isRequired x || hasRequired xs

||| True when every observation is acceptable, including for an empty list.
public export
allAcceptable : List Observation -> Bool
allAcceptable [] = True
allAcceptable (x :: xs) = acceptable x && allAcceptable xs

||| Passes only when at least one observation is required and all are acceptable;
||| an empty list is blocked. This pure algorithm assumes an external policy
||| enumerated all requirements and validated exemptions/admission. It cannot
||| authenticate a JSON receipt.
public export
decide : List Observation -> Verdict
decide xs = if hasRequired xs && allAcceptable xs then Passed else Blocked

-- The following are checked equalities, not comments about what CI ran.
public export
emptyCannotPass : decide [] = Blocked
emptyCannotPass = Refl

public export
positiveControl :
  decide [MkObservation Mandatory Applies CompletedSuccess CurrentRevision AdmissionVerified] = Passed
positiveControl = Refl

public export
exemptionsAloneCannotPass :
  decide [MkObservation Mandatory ExemptValidated Skipped RevisionUnknown AdmissionUnverified] = Blocked
exemptionsAloneCannotPass = Refl

public export
advisoryCannotDischarge :
  decide [ MkObservation Advisory Applies CompletedSuccess CurrentRevision AdmissionVerified
         , MkObservation Mandatory Applies CompletedFailure CurrentRevision AdmissionVerified
         ] = Blocked
advisoryCannotDischarge = Refl

||| An arbitrary tail cannot make a skipped applicable mandatory check pass.
public export
skippedRequiredCannotPass : (xs : List Observation) ->
  decide (MkObservation Mandatory Applies Skipped CurrentRevision AdmissionVerified :: xs) = Blocked
skippedRequiredCannotPass xs = Refl

||| An arbitrary tail cannot make a never-started applicable mandatory check
||| pass, even with a current revision and verified admission.
public export
neverStartedCannotPass : (xs : List Observation) ->
  decide (MkObservation Mandatory Applies NeverStarted CurrentRevision AdmissionVerified :: xs) = Blocked
neverStartedCannotPass xs = Refl

||| An arbitrary tail cannot make an applicable mandatory success from a
||| previous revision pass, even with verified admission.
public export
staleCannotPass : (xs : List Observation) ->
  decide (MkObservation Mandatory Applies CompletedSuccess PreviousRevision AdmissionVerified :: xs) = Blocked
staleCannotPass xs = Refl

||| An arbitrary tail cannot make an applicable mandatory success with revoked
||| admission pass, even on the current revision.
public export
revokedCannotPass : (xs : List Observation) ->
  decide (MkObservation Mandatory Applies CompletedSuccess CurrentRevision AdmissionRevoked :: xs) = Blocked
revokedCannotPass xs = Refl

||| An arbitrary tail cannot make an applicable mandatory success with unverified
||| admission pass, even on the current revision.
public export
unverifiedCannotPass : (xs : List Observation) ->
  decide (MkObservation Mandatory Applies CompletedSuccess CurrentRevision AdmissionUnverified :: xs) = Blocked
unverifiedCannotPass xs = Refl

public export
undeterminedCannotPass :
  decide [MkObservation Mandatory Undetermined CompletedSuccess CurrentRevision AdmissionVerified] = Blocked
undeterminedCannotPass = Refl

||| An applicable, unverified advisory bundle member cannot accompany PASS.
||| ExemptValidated remains a separately trusted policy exemption.
public export
unverifiedAdvisoryCannotSharePass :
  decide [ MkObservation Mandatory Applies CompletedSuccess CurrentRevision AdmissionVerified
         , MkObservation Advisory Applies CompletedSuccess CurrentRevision AdmissionUnverified
         ] = Blocked
unverifiedAdvisoryCannotSharePass = Refl

||| Verified advisory failures remain non-blocking for mandatory success.
public export
verifiedAdvisoryFailureNonblocking :
  decide [ MkObservation Mandatory Applies CompletedSuccess CurrentRevision AdmissionVerified
         , MkObservation Advisory Applies CompletedFailure CurrentRevision AdmissionVerified
         ] = Passed
verifiedAdvisoryFailureNonblocking = Refl

||| An admitted advisory result must still have run to completion on this revision.
public export
neverStartedAdvisoryCannotSharePass :
  decide [ MkObservation Mandatory Applies CompletedSuccess CurrentRevision AdmissionVerified
         , MkObservation Advisory Applies NeverStarted CurrentRevision AdmissionVerified
         ] = Blocked
neverStartedAdvisoryCannotSharePass = Refl

public export
runningAdvisoryCannotSharePass :
  decide [ MkObservation Mandatory Applies CompletedSuccess CurrentRevision AdmissionVerified
         , MkObservation Advisory Applies StillRunning CurrentRevision AdmissionVerified
         ] = Blocked
runningAdvisoryCannotSharePass = Refl

public export
skippedAdvisoryCannotSharePass :
  decide [ MkObservation Mandatory Applies CompletedSuccess CurrentRevision AdmissionVerified
         , MkObservation Advisory Applies Skipped CurrentRevision AdmissionVerified
         ] = Blocked
skippedAdvisoryCannotSharePass = Refl

public export
cancelledAdvisoryCannotSharePass :
  decide [ MkObservation Mandatory Applies CompletedSuccess CurrentRevision AdmissionVerified
         , MkObservation Advisory Applies Cancelled CurrentRevision AdmissionVerified
         ] = Blocked
cancelledAdvisoryCannotSharePass = Refl

public export
staleAdvisoryCannotSharePass :
  decide [ MkObservation Mandatory Applies CompletedSuccess CurrentRevision AdmissionVerified
         , MkObservation Advisory Applies CompletedSuccess PreviousRevision AdmissionVerified
         ] = Blocked
staleAdvisoryCannotSharePass = Refl

public export
unknownRevisionAdvisoryCannotSharePass :
  decide [ MkObservation Mandatory Applies CompletedSuccess CurrentRevision AdmissionVerified
         , MkObservation Advisory Applies CompletedFailure RevisionUnknown AdmissionVerified
         ] = Blocked
unknownRevisionAdvisoryCannotSharePass = Refl

||| A trusted policy exemption need not claim an observed run or admission.
public export
validatedExemptionCanSharePass :
  decide [ MkObservation Mandatory Applies CompletedSuccess CurrentRevision AdmissionVerified
         , MkObservation Advisory ExemptValidated NeverStarted RevisionUnknown AdmissionUnverified
         ] = Passed
validatedExemptionCanSharePass = Refl
