-- SPDX-License-Identifier: MPL-2.0
||| proven-lock-verdict FACTS_JSON
|||
||| Reads the facts the extractor emitted (schema proven-cicd/lock-facts/v1)
||| and prints the verdict. Exit codes:
|||   0  CONSISTENT
|||   1  INCONSISTENT (one REASON line per defect)
|||   2  NOT_RUN (unreadable or malformed facts, unresolved composite,
|||      closure that did not stabilise, or an empty lock)
||| Malformed input is never read as an empty, and so passing, repository.
module Proven.Lock.Main

import Assurance.GitHub
import Data.List
import Language.JSON
import Proven.Lock.Judge
import Proven.Lock.Model
import System
import System.File

%default total

field : String -> JSON -> Maybe JSON
field k (JObject fs) = lookup k fs
field _ _ = Nothing

str : JSON -> Maybe String
str (JString s) = Just s
str _ = Nothing

optStr : JSON -> Maybe (Maybe String)
optStr JNull = Just Nothing
optStr (JString s) = Just (Just s)
optStr _ = Nothing

||| Integral numbers only; GitHub ids fit a double exactly below 2^53.
int : JSON -> Maybe Integer
int (JNumber d) =
  let i = the Integer (cast d) in
  if cast i == d && d >= 0 && d < 9007199254740992.0 then Just i else Nothing
int _ = Nothing

optInt : JSON -> Maybe (Maybe Integer)
optInt JNull = Just Nothing
optInt v = map Just (int v)

list : (JSON -> Maybe a) -> JSON -> Maybe (List a)
list f (JArray vs) = traverse f vs
list _ _ = Nothing

strs : JSON -> Maybe (List String)
strs = list str

req : String -> (JSON -> Maybe a) -> JSON -> Maybe a
req k f v = field k v >>= f

node : JSON -> Maybe Node
node v = [| MkNode (req "direct" strs v) (req "locals" strs v) |]

composite : JSON -> Maybe (String, Node)
composite v = [| MkPair (req "id" str v) (node v) |]

workflow : JSON -> Maybe Workflow
workflow v = [| MkWorkflow (req "path" str v) (node v) (req "job_calls" strs v) |]

entry : JSON -> Maybe Entry
entry v = [| MkEntry (req "path" str v) (req "keys" strs v) |]

usesOf : JSON -> Maybe Uses
usesOf JNull = Just NoUses
usesOf (JString "MALFORMED") = Just UsesMalformed
usesOf v = map UsesList (strs v)

lockRecord : JSON -> Maybe LockRecord
lockRecord v =
  [| MkLockRecord (req "key" str v) (req "ref" optStr v) (req "commit" optStr v)
                  (req "owner_id" optInt v) (req "repo_id" optInt v)
                  (req "uses" usesOf v) |]

illegalAt : JSON -> Maybe (String, String)
illegalAt v = [| MkPair (req "at" str v) (req "uses" str v) |]

identity : JSON -> Maybe Identity
identity v =
  [| MkIdentity (req "repo" str v) (req "owner_id" int v) (req "repo_id" int v)
                (req "canonical" str v) |]

oracleOf : JSON -> Maybe (Maybe (List Identity))
oracleOf JNull = Just Nothing
oracleOf v = map Just (list identity v)

export
facts : JSON -> Maybe Facts
facts v = do
  "proven-cicd/lock-facts/v1" <- req "schema" str v | _ => Nothing
  [| MkFacts (req "composites" (list composite) v) (req "workflows" (list workflow) v)
             (req "entries" (list entry) v) (req "records" (list lockRecord) v)
             (req "illegal" (list illegalAt) v) (req "oracle" oracleOf v) |]

covering
notRun : List String -> IO ()
notRun whys = do
  putStrLn "NOT_RUN"
  traverse_ (\w => putStrLn ("WHY\t" ++ w)) whys
  exitWith (ExitFailure 2)

covering
report : (f : Facts) -> Outcome f -> IO ()
report f (Consistent _ _ unjudged) = do
  putStrLn "CONSISTENT"
  traverse_ (\u => putStrLn ("UNJUDGED\t" ++ u)) unjudged
report f (Inconsistent whys unjudged) = do
  putStrLn "INCONSISTENT"
  traverse_ (\r => putStrLn ("REASON\t" ++ show r)) whys
  traverse_ (\u => putStrLn ("UNJUDGED\t" ++ u)) unjudged
  exitWith (ExitFailure 1)
report f (NotRun whys) = notRun whys

covering
main : IO ()
main = do
  args <- getArgs
  case args of
    [_, path] => do
      input <- readFile path
      case input of
        Left _ => notRun ["facts file unreadable"]
        Right raw => case the (Maybe Facts) (strictJSON raw >>= facts) of
          Nothing => notRun ["facts are not valid proven-cicd/lock-facts/v1"]
          Just f => report f (judge f)
    _ => notRun ["usage: proven-lock-verdict FACTS_JSON"]
