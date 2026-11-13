-- SPDX-License-Identifier: MPL-2.0
||| The lock and pin verdict. `judge` is total. It returns `Consistent` only
||| with an `EdgesExact` certificate for every managed workflow and a `RefOk`
||| certificate for every record, so a consistent verdict cannot be produced
||| without the proofs. Fuel bounds only how long a search runs: running out
||| gives NOT RUN, never a pass.
module Proven.Lock.Judge

import Data.List
import Decidable.Equality
import Data.List.Elem
import Data.List.Quantifiers
import Data.Maybe
import Data.So
import Proven.Lock.Model

%default total

------------------------------------------------------------------------
-- Reasons

public export
data Reason
  = MissingEdge String String      -- workflow, key reached but not listed
  | BlindEmptyEntry String         -- workflow listed as [] but reaches keys
  | ExtraEdge String String        -- workflow, key listed but not reached
  | StaleEntry String              -- entry for a workflow that does not exist
  | DuplicateEntry String
  | KeyMalformed String
  | Tracking String String         -- location, key whose ref is not a SHA
  | SelfShaLeaf String
  | RefMissing String
  | CommitMismatch String
  | IdsMissing String
  | BadUses String
  | DanglingRecord String
  | UnusedRecord String
  | OwnerIdDrift String
  | Moved String String
  | Illegal String String

public export
Show Reason where
  show (MissingEdge w k) = "MissingTransitiveEdge\t" ++ w ++ "\t" ++ k
  show (BlindEmptyEntry w) = "BlindEmptyEntry\t" ++ w
  show (ExtraEdge w k) = "StaleRef\t" ++ w ++ "\t" ++ k
  show (StaleEntry w) = "StaleEntry\t" ++ w
  show (DuplicateEntry w) = "DuplicateEntry\t" ++ w
  show (KeyMalformed k) = "KeyMalformed\t" ++ k
  show (Tracking w k) = "Tracking\t" ++ w ++ "\t" ++ k
  show (SelfShaLeaf k) = "SelfShaLeaf\t" ++ k
  show (RefMissing k) = "RefMissing\t" ++ k
  show (CommitMismatch k) = "CommitMismatch\t" ++ k
  show (IdsMissing k) = "IdsMissing\t" ++ k
  show (BadUses k) = "BadUses\t" ++ k
  show (DanglingRecord k) = "DanglingRecord\t" ++ k
  show (UnusedRecord k) = "UnusedRecord\t" ++ k
  show (OwnerIdDrift k) = "OwnerIdDrift\t" ++ k
  show (Moved k c) = "Moved\t" ++ k ++ "\t" ++ c
  show (Illegal at u) = "Illegal\t" ++ at ++ "\t" ++ u

------------------------------------------------------------------------
-- Deciders that return proofs

public export
decSub : (xs, ys : List String) -> Maybe (Sub xs ys)
decSub [] ys = Just []
decSub (x :: xs) ys = case elemDec x ys of
  Yes e => map (e ::) (decSub xs ys)
  No _ => Nothing

public export
decNodeIn : (vs, ss : List String) -> (n : Node) -> Maybe (NodeIn vs ss n)
decNodeIn vs ss n = do
  l <- decSub (locals n) vs
  d <- decSub (direct n) ss
  Just (l, d)

public export
decClosedOver : (g : List (String, Node)) -> (vs, ss, cs : List String) ->
  Maybe (All (\c => (m : Node ** (resolve c g = Just m, NodeIn vs ss m))) cs)
decClosedOver g vs ss [] = Just []
decClosedOver g vs ss (c :: cs) with (resolve c g) proof p
  _ | Nothing = Nothing
  _ | Just m = do
        nin <- decNodeIn vs ss m
        rest <- decClosedOver g vs ss cs
        Just ((m ** (p, nin)) :: rest)

public export
decClosed : (g : List (String, Node)) -> (vs, ss : List String) ->
            Maybe (Closed g vs ss)
decClosed g vs ss = decClosedOver g vs ss vs

------------------------------------------------------------------------
-- The walk

||| One round: add what every visited composite contributes.
public export
step : List (String, Node) -> (List String, List String) ->
       (List String, List String)
step g (vs, ss) = foldl add (vs, ss) vs
  where
    add : (List String, List String) -> String -> (List String, List String)
    add (v, s) c = case resolve c g of
      Nothing => (v, s)
      Just m => (mergeKeys v (locals m), mergeKeys s (direct m))

public export
iter : Nat -> List (String, Node) -> (List String, List String) ->
       (List String, List String)
iter Z _ acc = acc
iter (S f) g acc = iter f g (step g acc)

||| The candidate closure. It is only trusted after `decClosed` succeeds.
public export
walk : List (String, Node) -> Node -> (List String, List String)
walk g n = iter (S (length g)) g (dedup (locals n), dedup (direct n))

------------------------------------------------------------------------
-- Reach search (sound by construction; fuel only limits it)

public export
withElems : (xs : List a) -> List (x : a ** Elem x xs)
withElems [] = []
withElems (x :: xs) = (x ** Here) :: map (\(y ** e) => (y ** There e)) (withElems xs)

mutual
  public export
  findReach : Nat -> (g : List (String, Node)) -> (n : Node) -> (k : String) ->
              Maybe (Reach g n k)
  findReach fuel g n k = case elemDec k (direct n) of
    Yes e => Just (ByStep e)
    No _ => case fuel of
      Z => Nothing
      S f => tryAll f g n k (withElems (locals n))

  public export
  tryAll : Nat -> (g : List (String, Node)) -> (n : Node) -> (k : String) ->
           List (c : String ** Elem c (locals n)) -> Maybe (Reach g n k)
  tryAll f g n k [] = Nothing
  tryAll f g n k ((c ** e) :: rest) = case viaOne f g k c of
    Just (m ** (p, r)) => Just (ByComposite e p r)
    Nothing => tryAll f g n k rest

  public export
  viaOne : Nat -> (g : List (String, Node)) -> (k : String) -> (c : String) ->
           Maybe (m : Node ** (resolve c g = Just m, Reach g m k))
  viaOne f g k c = viaMaybe f g k c (resolve c g) Refl

  public export
  viaMaybe : Nat -> (g : List (String, Node)) -> (k : String) -> (c : String) ->
             (found : Maybe Node) -> resolve c g = found ->
             Maybe (m : Node ** (resolve c g = Just m, Reach g m k))
  viaMaybe f g k c Nothing _ = Nothing
  viaMaybe f g k c (Just m) p = case findReach f g m k of
    Nothing => Nothing
    Just r => Just (m ** (p, r))

public export
allowedAll : Nat -> (g : List (String, Node)) -> (n : Node) -> (calls : List String) ->
             (ks : List String) -> Maybe (All (Allowed g n calls) ks)
allowedAll f g n calls [] = Just []
allowedAll f g n calls (k :: ks) = do
  a <- case elemDec k calls of
         Yes e => Just (Called e)
         No _ => map Reached (findReach f g n k)
  rest <- allowedAll f g n calls ks
  Just (a :: rest)

------------------------------------------------------------------------
-- Per-workflow edge judgement

public export
data EdgeResult : List (String, Node) -> Node -> List String -> List String -> Type where
  Exact : EdgesExact g n calls e -> EdgeResult g n calls e
  Wrong : List Reason -> EdgeResult g n calls e
  Refused : String -> EdgeResult g n calls e

public export
judgeEdges : (path : String) -> (g : List (String, Node)) -> (n : Node) ->
             (calls, e : List String) -> EdgeResult g n calls e
judgeEdges path g n calls e =
  let (vs, ss) = walk g n
      unresolved = filter (\c => not (has (resolve c g))) vs
   in case unresolved of
        (c :: _) => Refused ("composite metadata missing: " ++ c ++ " (from " ++ path ++ ")")
        [] => case decClosed g vs ss of
          Nothing => Refused ("closure did not stabilise for " ++ path)
          Just cl => case decNodeIn vs ss n of
            Nothing => Refused ("closure does not contain the workflow's own refs: " ++ path)
            Just nin =>
              let missing = filter (\k => not (elem k e)) ss
                  extra = filter (\k => not (elem k ss || elem k calls)) e
               in case (missing, extra) of
                    ([], []) => case decSub ss e of
                      Nothing => Refused ("subset decision disagreed for " ++ path)
                      Just sub => case allowedAll (S (length g)) g n calls e of
                        Nothing => Refused ("no reach proof found for a listed key in " ++ path)
                        Just ok => Exact (exact cl nin sub ok)
                    _ => Wrong (missingReasons e missing ++ map (ExtraEdge path) extra)
  where
    missingReasons : List String -> List String -> List Reason
    missingReasons [] (_ :: _) = [BlindEmptyEntry path]
    missingReasons _ ms = map (MissingEdge path) ms

------------------------------------------------------------------------
-- Records

public export
decRefOk : (calls : List String) -> (r : LockRecord) -> Either Reason (RefOk calls r)
decRefOk calls r with (ref r) proof pr
  _ | Nothing = Left (RefMissing (key r))
  _ | Just x = case chooseSo (isSha40 x) of
      Right notSha => case chooseSo (x /= "") of
        Left nonEmpty => Right (NamedRef pr notSha nonEmpty)
        Right _ => Left (RefMissing (key r))
      Left sha => case chooseSo (keyRef (key r) == Just x) of
        Right _ => Left (SelfShaLeaf (key r))
        Left kr => case elemDec (key r) calls of
          No _ => Left (SelfShaLeaf (key r))
          Yes call => case chooseSo (notMalformed (uses r)) of
            Left ok => Right (CallerEdge pr kr sha call ok)
            Right _ => Left (BadUses (key r))

public export
validCommit : String -> Bool
validCommit c = case unpack c of
  ('s' :: 'h' :: 'a' :: '1' :: '-' :: rest) => isSha40 (pack rest)
  _ => False

public export
recordReasons : LockRecord -> List Reason
recordReasons r =
  let k = key r in
  case keyRef k of
    Nothing => [KeyMalformed k]
    Just kr =>
      -- A tag-keyed record is valid to the runner: its `commit` is the pin.
      -- "Lock keys must be SHAs" is canon policy, judged by a separate rule.
      (case commit r of
         Just c =>
           if not (validCommit c) || (isSha40 kr && c /= "sha1-" ++ kr)
              then [CommitMismatch k] else []
         Nothing => [CommitMismatch k]) ++
      (if has r.ownerId && has r.repoId then [] else [IdsMissing k]) ++
      (case uses r of
         UsesMalformed => [BadUses k]
         _ => [])

public export
nested : LockRecord -> List String
nested r = case uses r of
  UsesList ks => ks
  _ => []

public export
oracleReasons : List Identity -> LockRecord -> List Reason
oracleReasons ids r = case keyRepo (key r) of
  Nothing => []
  Just rp => case firstWhere (\i => i.repo == rp) ids of
    Nothing => []
    Just i =>
      (if i.canonical /= rp then [Moved (key r) i.canonical] else []) ++
      (case (r.ownerId, r.repoId) of
         (Just o, Just rid) =>
           if o /= i.ownerId || rid /= i.repoId then [OwnerIdDrift (key r)] else []
         _ => [])

public export
decAllRefOk : (calls : List String) -> (rs : List LockRecord) ->
              Either (List Reason) (All (RefOk calls) rs)
decAllRefOk calls [] = Right []
decAllRefOk calls (r :: rs) = case (decRefOk calls r, decAllRefOk calls rs) of
  (Right ok, Right oks) => Right (ok :: oks)
  (Left why, Right _) => Left [why]
  (Right _, Left whys) => Left whys
  (Left why, Left whys) => Left (why :: whys)

------------------------------------------------------------------------
-- Whole verdict

public export
entryOf : Facts -> Workflow -> List String
entryOf f w = maybe [] keys (firstWhere (\e => path e == path w) (entries f))

public export
isManaged : Facts -> Workflow -> Bool
isManaged f w = has (firstWhere (\e => path e == path w) (entries f))

public export
allCalls : Facts -> List String
allCalls f = concatMap jobCalls (workflows f)

public export
data Outcome : Facts -> Type where
  ||| Every managed workflow's entry is exact and every record's ref is
  ||| well represented. `unjudged` names checks that could not run (no oracle).
  Consistent : All (\w => EdgesExact (composites f) (node w) (jobCalls w) (entryOf f w))
                   (filter (isManaged f) (workflows f)) ->
               All (RefOk (allCalls f)) (records f) ->
               (unjudged : List String) -> Outcome f
  Inconsistent : List Reason -> (unjudged : List String) -> Outcome f
  NotRun : List String -> Outcome f

public export
edgesAll : (f : Facts) -> (ws : List Workflow) ->
  (List String, List Reason,
   Maybe (All (\w => EdgesExact (composites f) (node w) (jobCalls w) (entryOf f w)) ws))
edgesAll f [] = ([], [], Just [])
edgesAll f (w :: ws) =
  let (refused, wrong, cert) = edgesAll f ws in
  case judgeEdges (path w) (composites f) (node w) (jobCalls w) (entryOf f w) of
    Exact ex => (refused, wrong, map (ex ::) cert)
    Wrong rs => (refused, rs ++ wrong, Nothing)
    Refused why => (why :: refused, wrong, Nothing)

||| Keys an unmanaged workflow names whose ref is not a full SHA. In a managed
||| workflow the lock record's `commit` pins a tag ref, so it is not tracking.
public export
trackingReasons : Workflow -> List Reason
trackingReasons w =
  map (Tracking (path w))
      (filter (\k => maybe True (not . isSha40) (keyRef k)) (direct (node w)))

||| Records nothing names (no entry and no nested `uses:`), and names that no
||| record keys.
public export
closureReasons : Facts -> List Reason
closureReasons f =
  let named = dedup (concatMap keys (entries f) ++ concatMap nested (records f))
      keyed = map key (records f)
   in map DanglingRecord (filter (\k => not (elem k keyed)) named) ++
      map UnusedRecord (filter (\k => not (elem k named)) keyed)

public export
entryReasons : Facts -> List Reason
entryReasons f =
  let paths = map path (entries f)
      wpaths = map path (workflows f)
   in map StaleEntry (filter (\p => not (elem p wpaths)) paths) ++
      map DuplicateEntry (dedup (filter (\p => length (filter (== p) paths) > 1) paths))

public export
judge : (f : Facts) -> Outcome f
judge f =
  case records f of
    [] => NotRun ["the lock keys no dependencies; zero records is no assurance"]
    _ =>
      let (refused, edgeWrong, edgeCert) = edgesAll f (filter (isManaged f) (workflows f))
          unjudged = case oracle f of
                       Nothing => ["OwnerIdDrift and Moved: no oracle snapshot supplied"]
                       Just _ => []
          other = map (uncurry Illegal) (illegal f) ++
                  concatMap trackingReasons
                    (filter (not . isManaged f) (workflows f)) ++
                  entryReasons f ++
                  concatMap recordReasons (records f) ++
                  closureReasons f ++
                  maybe [] (\ids => concatMap (oracleReasons ids) (records f)) (oracle f)
       in case refused of
            (_ :: _) => NotRun refused
            [] => case (edgeCert, decAllRefOk (allCalls f) (records f), edgeWrong ++ other) of
              (Just ec, Right rc, []) => Consistent ec rc unjudged
              (_, Left refWhy, why) => Inconsistent (refWhy ++ why) unjudged
              (_, Right _, why@(_ :: _)) => Inconsistent why unjudged
              (Nothing, Right _, []) =>
                NotRun ["edge certificate missing without a reason (kernel defect)"]

public export
isConsistent : Outcome f -> Bool
isConsistent (Consistent _ _ _) = True
isConsistent _ = False
