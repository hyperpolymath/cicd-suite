-- SPDX-License-Identifier: MPL-2.0
||| Compile-time controls for the lock kernel.
|||
||| Positive control: the compiler evaluates `judge` on a well-formed fixture
||| and must find it CONSISTENT.
|||
||| Impossibility controls: for each historical incident shape, a proof that
||| NO certificate exists, so no judge, however written, could return
||| CONSISTENT for it. They are stronger than evaluating one judge on one input.
|||
||| tests/proven-lock-proofs.sh appends counterfeit certificates to a copy of
||| this file and requires the compiler to reject each one by name.
module Proven.Lock.Controls

import Data.List.Elem
import Data.So
import Proven.Lock.Judge
import Proven.Lock.Model

%default total

public export
shaB : String
shaB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

public export
checkoutKey : String
checkoutKey = "actions/checkout@v7.0.1"

public export
leafKey : String
leafKey = "x/leaf@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

public export
checkout : LockRecord
checkout = MkLockRecord checkoutKey (Just "v7.0.1")
             (Just "sha1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") (Just 1) (Just 2) NoUses

public export
leaf : String -> LockRecord
leaf r = MkLockRecord leafKey (Just r) (Just ("sha1-" ++ shaB)) (Just 3) (Just 4) NoUses

||| One composite, `actions/probe`, whose only step uses the leaf.
public export
probe : List (String, Node)
probe = [("actions/probe", MkNode [leafKey] [])]

||| A workflow that uses checkout directly and the leaf only through the probe.
public export
wfNode : Node
wfNode = MkNode [checkoutKey] ["actions/probe"]

public export
wf : Workflow
wf = MkWorkflow ".github/workflows/a.yml" wfNode []

public export
good : Facts
good = MkFacts probe [wf]
         [MkEntry ".github/workflows/a.yml" [checkoutKey, leafKey]]
         [checkout, leaf "v1"] [] Nothing

||| The judge, evaluated by the compiler, accepts the well-formed fixture.
public export
goodIsConsistent : isConsistent (judge Controls.good) = True
goodIsConsistent = Refl

||| An empty lock is never consistent: zero records is no assurance.
public export
noRecordsIsNot :
  isConsistent (judge (MkFacts Controls.probe [Controls.wf]
                               [MkEntry ".github/workflows/a.yml" []] [] [] Nothing)) = False
noRecordsIsNot = Refl

||| The leaf is reached, through the composite.
public export
leafReached : Reach Controls.probe Controls.wfNode Controls.leafKey
leafReached = ByComposite Here Refl (ByStep Here)

||| Run 35786094563: an entry that drops a key reached only through a
||| composite has no exactness certificate.
public export
droppedHasNoCertificate :
  EdgesExact Controls.probe Controls.wfNode [] [Controls.checkoutKey] -> Void
droppedHasNoCertificate ex = case listsAll ex leafKey leafReached of
  There e => absurd e

||| A blind `[]` entry for a workflow that reaches keys has no certificate.
public export
blindEmptyHasNoCertificate : EdgesExact Controls.probe Controls.wfNode [] [] -> Void
blindEmptyHasNoCertificate ex = emptyMeansNothingReached ex leafReached

||| Svalinn run 40108154356: a leaf whose ref repeats its own SHA, not called
||| as a job-level reusable, has no representation certificate.
public export
selfShaLeafHasNoCertificate : RefOk [] (Controls.leaf Controls.shaB) -> Void
selfShaLeafHasNoCertificate (NamedRef Refl notSha _) = absurd notSha
selfShaLeafHasNoCertificate (CallerEdge _ _ _ call _) = absurd call

||| standards#1290: the same record IS admissible when a workflow here calls
||| its key as a job-level reusable workflow.
public export
callerEdgeCertified : RefOk [Controls.leafKey] (Controls.leaf Controls.shaB)
callerEdgeCertified = CallerEdge Refl Oh Oh Here Oh
