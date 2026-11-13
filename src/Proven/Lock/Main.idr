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

||| JSON string literal. Escapes the quote, the backslash and every control
||| character, so any key, path or reason text is emitted as one valid string.
jsonString : String -> String
jsonString s = "\"" ++ concatMap esc (unpack s) ++ "\""
  where
    hex : Int -> String
    digit : Int -> Char
    digit d = chr (if d < 10 then 48 + d else 87 + d)
    hex n = pack [digit (div n 16), digit (mod n 16)]
    esc : Char -> String
    esc '"' = "\\\""
    esc '\\' = "\\\\"
    esc '\n' = "\\n"
    esc '\t' = "\\t"
    esc '\r' = "\\r"
    esc c = if ord c < 32 then "\\u00" ++ hex (ord c) else pack [c]

opt : Maybe String -> String
opt Nothing = "null"
opt (Just s) = jsonString s

detail : Reason -> Maybe String
detail (Moved _ c) = Just c
detail (Illegal _ u) = Just u
detail _ = Nothing

||| One finding, in the executor contract: {reason, record_key, workflow_file,
||| line, detail}. `line` is null until the extractor carries positions.
finding : Reason -> String
finding r = let (name, k, w) = fields r in
  "{\"reason\":" ++ jsonString name ++ ",\"record_key\":" ++ opt k ++
  ",\"workflow_file\":" ++ opt w ++ ",\"line\":null,\"detail\":" ++ opt (detail r) ++ "}"

jsonList : List String -> String
jsonList xs = "[" ++ concat (intersperse "," (map jsonString xs)) ++ "]"

||| The last line in --json mode: the verdict, what was not judged, and why a
||| run did not happen. Exit codes are the same in both modes.
status : String -> List String -> List String -> String
status v unjudged whys =
  "{\"verdict\":" ++ jsonString v ++ ",\"unjudged\":" ++ jsonList unjudged ++ ",\"why\":" ++ jsonList whys ++ "}"

public export
data Output = Text | Json

covering
notRun : Output -> List String -> IO ()
notRun Text whys = do
  putStrLn "NOT_RUN"
  traverse_ (\w => putStrLn ("WHY\t" ++ w)) whys
  exitWith (ExitFailure 2)
notRun Json whys = do
  putStrLn (status "NOT_RUN" [] whys)
  exitWith (ExitFailure 2)

covering
report : Output -> (f : Facts) -> Outcome f -> IO ()
report Text f (Consistent _ _ unjudged) = do
  putStrLn "CONSISTENT"
  traverse_ (\u => putStrLn ("UNJUDGED\t" ++ u)) unjudged
report Json f (Consistent _ _ unjudged) =
  putStrLn (status "CONSISTENT" unjudged [])
report Text f (Inconsistent whys unjudged) = do
  putStrLn "INCONSISTENT"
  traverse_ (\r => putStrLn ("REASON\t" ++ show r)) whys
  traverse_ (\u => putStrLn ("UNJUDGED\t" ++ u)) unjudged
  exitWith (ExitFailure 1)
report Json f (Inconsistent whys unjudged) = do
  traverse_ (putStrLn . finding) whys
  putStrLn (status "INCONSISTENT" unjudged [])
  exitWith (ExitFailure 1)
report mode f (NotRun whys) = notRun mode whys

||| One certified entry per workflow: {workflow, managed, keys} or
||| {workflow, managed, refused}. Exit 0 when every entry is certified, 2 if any
||| is refused: a partial relock is never written as if it were whole.
covering
relock : String -> IO ()
relock file = do
  input <- readFile file
  case input of
    Left _ => notRun Json ["facts file unreadable"]
    Right raw => case the (Maybe Facts) (strictJSON raw >>= facts) of
      Nothing => notRun Json ["facts are not valid proven-cicd/lock-facts/v1"]
      Just f => do
        refused <- traverse (one f) (workflows f)
        if any id refused then exitWith (ExitFailure 2) else pure ()
  where
    managedJson : Facts -> Workflow -> String
    managedJson f w = if isManaged f w then "true" else "false"
    one : Facts -> Workflow -> IO Bool
    one f w = case relockEntry (composites f) w of
      Left why => do
        putStrLn ("{\"workflow\":" ++ jsonString (path w) ++ ",\"managed\":" ++ managedJson f w ++ ",\"refused\":" ++ jsonString why ++ "}")
        pure True
      Right (e ** _) => do
        putStrLn ("{\"workflow\":" ++ jsonString (path w) ++ ",\"managed\":" ++ managedJson f w ++ ",\"keys\":" ++ jsonList e ++ "}")
        pure False

covering
run : Output -> String -> IO ()
run mode path = do
  input <- readFile path
  case input of
    Left _ => notRun mode ["facts file unreadable"]
    Right raw => case the (Maybe Facts) (strictJSON raw >>= facts) of
      Nothing => notRun mode ["facts are not valid proven-cicd/lock-facts/v1"]
      Just f => report mode f (judge f)

||| proven-lock-verdict [--json] FACTS_JSON
||| --json: one object per finding {reason, record_key, workflow_file, line,
||| detail}, then one status object {verdict, unjudged, why}. Same exit codes.
covering
main : IO ()
main = do
  args <- getArgs
  case args of
    [_, "--json", path] => run Json path
    [_, "--relock", path] => relock path
    [_, path] => run Text path
    _ => notRun Text ["usage: proven-lock-verdict [--json | --relock] FACTS_JSON"]
