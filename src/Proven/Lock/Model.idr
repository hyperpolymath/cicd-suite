-- SPDX-License-Identifier: MPL-2.0
||| The lock and pin model: facts, the reach relation and the theorems the
||| verdict relies on. The judge (Proven.Lock.Judge) may only report a
||| workflow's lock entry as exact by constructing an `EdgesExact` value, and
||| it may only construct one from a decided closure (`Closed`) plus a reach
||| proof for every listed key.
|||
||| Assumptions, stated here because the theorems depend on them:
||| * the facts are a faithful extraction of the repository at one commit
|||   (the extractor is conformance-tested, not proven);
||| * an oracle snapshot, when present, is true at the time of the check, and
|||   nothing changes between extraction and verdict.
module Proven.Lock.Model

import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.So

%default total

||| A local node: a workflow or a same-repository composite action.
||| `direct` holds the normalised remote keys (`owner/repo@ref`) of its STEP-level
||| `uses:`. `locals` holds same-repository composite ids. Job-level reusable
||| calls are not here: the runner validates a callee against the callee's own
||| lock at the pinned commit, and a caller's entry may omit them (measured,
||| standards#968: 12 of 12 sampled callers created jobs with the ref absent).
public export
record Node where
  constructor MkNode
  direct : List String
  locals : List String

public export
record Workflow where
  constructor MkWorkflow
  path : String
  node : Node
  ||| Remote keys called as job-level reusable workflows. An entry MAY list them.
  jobCalls : List String

||| A record's nested `uses:`. A scalar or mapping is malformed, never an edge.
public export
data Uses = NoUses | UsesList (List String) | UsesMalformed

public export
record LockRecord where
  constructor MkLockRecord
  key : String
  ref : Maybe String
  commit : Maybe String
  ownerId : Maybe Integer
  repoId : Maybe Integer
  uses : Uses

public export
record Entry where
  constructor MkEntry
  path : String
  keys : List String

||| One oracle row: what the platform says about a repository right now.
public export
record Identity where
  constructor MkIdentity
  repo : String
  ownerId : Integer
  repoId : Integer
  canonical : String

public export
record Facts where
  constructor MkFacts
  composites : List (String, Node)
  workflows : List Workflow
  entries : List Entry
  records : List LockRecord
  ||| (location, raw `uses:`) pairs the extractor found illegal (`../`, `$/` in
  ||| unsupported positions, expressions).
  illegal : List (String, String)
  oracle : Maybe (List Identity)

------------------------------------------------------------------------
-- Reach

||| Composite resolution. One named function, so every proof and decider
||| refers to the same definition.
public export
resolve : String -> List (String, Node) -> Maybe Node
resolve c [] = Nothing
resolve c ((d, m) :: rest) = if c == d then Just m else resolve c rest

||| `Reach g n k`: the remote key `k` is reached from node `n`, either
||| directly or through a chain of same-repository composites present in `g`.
public export
data Reach : (g : List (String, Node)) -> Node -> String -> Type where
  ByStep : Elem k (direct n) -> Reach g n k
  ByComposite : {m : Node} -> Elem c (locals n) -> resolve c g = Just m ->
        Reach g m k -> Reach g n k

public export
Sub : List String -> List String -> Type
Sub xs ys = All (\x => Elem x ys) xs

||| `n` contributes nothing outside the visited set `vs` and key set `ss`.
public export
NodeIn : List String -> List String -> Node -> Type
NodeIn vs ss n = (Sub (locals n) vs, Sub (direct n) ss)

||| Every visited composite resolves in `g` and contributes nothing outside
||| (`vs`, `ss`). An unresolved composite makes the closure undecided, never
||| empty.
public export
Closed : List (String, Node) -> List String -> List String -> Type
Closed g vs ss =
  All (\c => (m : Node ** (resolve c g = Just m, NodeIn vs ss m))) vs

export
allElem : {0 p : a -> Type} -> All p xs -> Elem x xs -> p x
allElem (px :: _) Here = px
allElem (_ :: pxs) (There e) = allElem pxs e

justInj : {0 a, b : t} -> Just a = Just b -> a = b
justInj Refl = Refl

||| Walk completeness. If (`vs`, `ss`) is closed and contains `n`'s own
||| contribution, then every key reachable from `n` is in `ss`.
export
complete : Closed g vs ss -> NodeIn vs ss n -> Reach g n k -> Elem k ss
complete cl (_, dirs) (ByStep e) = allElem dirs e
complete cl (locs, dirs) (ByComposite ec lk r) =
  case allElem cl (allElem locs ec) of
    (m' ** (lk', nin)) =>
      let eq = justInj (trans (sym lk) lk') in
          complete cl (replace {p = NodeIn vs ss} (sym eq) nin) r

------------------------------------------------------------------------
-- Exact lock entries

||| A listed key is admissible when the workflow reaches it by steps, or calls
||| it as a job-level reusable workflow.
public export
data Allowed : List (String, Node) -> Node -> List String -> String -> Type where
  Reached : Reach g n k -> Allowed g n calls k
  Called : Elem k calls -> Allowed g n calls k

||| A workflow's lock entry is exact: it lists every key the workflow reaches
||| by steps (walk completeness), and every key it lists is reached or called
||| (no stale entry).
public export
record EdgesExact (g : List (String, Node)) (n : Node) (calls : List String)
                  (entry : List String) where
  constructor MkEdgesExact
  listsAll : (k : String) -> Reach g n k -> Elem k entry
  listsOnly : All (Allowed g n calls) entry

||| An exact certificate follows from a closed walk whose keys are all listed,
||| plus an admissibility proof for each listed key.
export
exact : Closed g vs ss -> NodeIn vs ss n -> Sub ss entry ->
        All (Allowed g n calls) entry -> EdgesExact g n calls entry
exact cl nin sub ok =
  MkEdgesExact (\k, r => allElem sub (complete cl nin r)) ok

||| A `[]` entry is admissible only for a workflow that reaches nothing by
||| steps. (Job-level calls may be absent from an entry; see `Workflow`.)
export
emptyMeansNothingReached : {k : String} -> EdgesExact g n calls [] -> Reach g n k -> Void
emptyMeansNothingReached ex r = absurd (listsAll ex k r)

||| ...and it is always admissible for one that reaches nothing.
export
nothingReachedAdmitsEmpty : ((k : String) -> Reach g n k -> Void) ->
                            EdgesExact g n calls []
nothingReachedAdmitsEmpty none = MkEdgesExact (\k, r => absurd (none k r)) []

------------------------------------------------------------------------
-- Record representation

public export
isLowerHex : Char -> Bool
isLowerHex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')

public export
isSha40 : String -> Bool
isSha40 s = let cs = unpack s in length cs == 40 && all isLowerHex cs

||| The ref part of a well-formed `owner/repo@ref` key.
public export
keyRef : String -> Maybe String
keyRef s = case break (== '@') (unpack s) of
  (repo@(_ :: _), '@' :: ref@(_ :: _)) =>
    if elem '@' ref || not (elem '/' repo) then Nothing else Just (pack ref)
  _ => Nothing

public export
keyRepo : String -> Maybe String
keyRepo s = case break (== '@') (unpack s) of
  (repo@(_ :: _), '@' :: _ :: _) => Just (pack repo)
  _ => Nothing

public export
notMalformed : Uses -> Bool
notMalformed UsesMalformed = False
notMalformed _ = True

||| The representation rule for a record's `ref:` (runner: "invalid lockfile
||| pin", standards#1271 and #1290). A ref names a tag or branch; it may repeat
||| the key's own SHA only for a reusable-workflow edge, meaning a key that a
||| workflow in this repository calls as a job-level reusable, with a nested
||| `uses:` that is not malformed. A `uses:` list alone does not qualify: a
||| composite action carries one too.
public export
data RefOk : (calls : List String) -> LockRecord -> Type where
  NamedRef : ref r = Just x -> So (not (isSha40 x)) -> So (x /= "") ->
             RefOk calls r
  CallerEdge : ref r = Just x -> keyRef (key r) = Just x -> So (isSha40 x) ->
               Elem (key r) calls -> So (notMalformed (uses r)) ->
               RefOk calls r
