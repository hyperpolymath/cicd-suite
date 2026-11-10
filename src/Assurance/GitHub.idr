-- SPDX-License-Identifier: MPL-2.0
module Assurance.GitHub

import Assurance.Verdict
import Data.List
import Data.String
import Language.JSON
import Language.JSON.Lexer
import Language.JSON.Parser
import Language.JSON.Tokens
import Text.Token

%default total

-- The pinned contrib parser retains JObject fields as a list. Checking that
-- list before jq materializes objects detects repeated keys for every value
-- shape, including an object/array followed by an admissible scalar.
--
-- This finite API schema supports unescaped ASCII object keys only. Inspect
-- their raw tokens first: alternate escapes and non-ASCII keys are UNKNOWN,
-- not delegated to potentially different string-normalization rules.
plainKey : String -> Bool
plainKey raw = all (\c => ord c >= 32 && ord c <= 126 && c /= '\\') (unpack raw)

plainKeys : List (WithBounds JSONToken) -> Bool
plainKeys [] = True
plainKeys [_] = True
plainKeys (first :: second :: rest) =
  let this = case (first.val, second.val) of
               (Tok JTString raw, Tok (JTPunct Colon) _) => plainKey raw
               _ => True
   in this && plainKeys (second :: rest)

mutual
  uniqueFields : JSON -> Bool
  uniqueFields (JObject fields) = uniqueObject [] fields
  uniqueFields (JArray values) = uniqueValues values
  uniqueFields _ = True

  uniqueObject : List String -> List (String, JSON) -> Bool
  uniqueObject seen [] = True
  uniqueObject seen ((key, value) :: rest) =
    not (elem key seen) && uniqueFields value && uniqueObject (key :: seen) rest

  uniqueValues : List JSON -> Bool
  uniqueValues [] = True
  uniqueValues (value :: rest) = uniqueFields value && uniqueValues rest

public export
strictJSON : String -> Maybe JSON
strictJSON raw = do
  tokens <- lexJSON raw
  if plainKeys (filter (not . ignored) tokens)
     then do
       value <- parseJSON tokens
       if uniqueFields value then Just value else Nothing
     else Nothing

-- These are internal wire labels emitted only by the checked collector.
-- No external JSON constructor name grants AdmissionVerified or an exemption.
-- This initial route has no advisory/conditional/exemption admission.
observation : JSON -> Maybe Observation
observation (JString "PASSED") =
  Just (MkObservation Mandatory Applies CompletedSuccess CurrentRevision AdmissionVerified)
observation (JString "FAILED") =
  Just (MkObservation Mandatory Applies CompletedFailure CurrentRevision AdmissionUnverified)
observation (JString "PENDING") =
  Just (MkObservation Mandatory Applies StillRunning CurrentRevision AdmissionUnverified)
observation (JString "UNKNOWN") =
  Just (MkObservation Mandatory Applies NeverStarted RevisionUnknown AdmissionUnverified)
observation _ = Nothing

wireValues : List JSON -> Maybe (List Observation)
wireValues [] = Just []
wireValues (value :: rest) = do
  first <- observation value
  remaining <- wireValues rest
  Just (first :: remaining)

public export
wireObservations : JSON -> Maybe (List Observation)
wireObservations (JArray values) =
  if length values <= 64 then wireValues values else Nothing
wireObservations _ = Nothing
