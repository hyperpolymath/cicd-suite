-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- Gate.A2ml — line-oriented extraction for a2ml / Nickel-ish manifests.
--
-- This is NOT a parser for either language (deed-lint owns deed grammar;
-- the K9 validator owns K9 semantics). It is exactly enough to find flat
-- `key = value` and `key = [ "a", "b" ]` assignments for a fixed set of
-- policy keys, including arrays that span several lines.

module Gate.A2ml

import Data.List
import Data.String
import Gate.Text

%default total

||| A policy token attributed to the file it came from.
public export
record PolicyValue where
  constructor MkPolicy
  key   : String
  token : String
  file  : String

||| Keys whose flat list (or scalar) value is a DENY-list.
export
denyKeys : List String
denyKeys =
  [ "banned", "ban", "deny", "forbid", "forbids", "forbidden", "prohibited"
  , "blocked", "blocklist", "blacklist", "denylist", "disallowed"
  , "banned_languages", "no_unsafe"
  ]

||| Keys whose flat list (or scalar) value is an ALLOW-list.
export
allowKeys : List String
allowKeys =
  [ "languages", "allow", "allows", "allowed", "allowlist", "whitelist"
  , "sanctioned", "permitted", "endorsed", "supported"
  ]

export
isPolicyKey : String -> Bool
isPolicyKey k = elem k denyKeys || elem k allowKeys

||| Normalise a raw array/scalar fragment into a policy token, or Nothing.
export
nonceToken : String -> Maybe String
nonceToken raw =
  let cleaned = pack (filter keep (unpack (toLower raw)))
  in if strLength cleaned >= 2 then Just cleaned else Nothing
  where
    keep : Char -> Bool
    keep c = isAlphaNum c || c == '-' || c == '_' || c == '.' || c == '/' || c == '+'

||| Split an array body on commas and extract normalised tokens.
export
arrayTokens : String -> List String
arrayTokens body =
  mapMaybe nonceToken (splitChars ',' body)


||| First index of a character, if present.
export
elemIndex : Char -> List Char -> Maybe Nat
elemIndex c cs = go 0 cs
  where
    go : Nat -> List Char -> Maybe Nat
    go _ [] = Nothing
    go n (x :: xs) = if x == c then Just n else go (S n) xs

||| Break a string at the first occurrence of a character.
export
breakOn : Char -> String -> Maybe (String, String)
breakOn c s =
  let cs = unpack s
  in case elemIndex c cs of
       Nothing => Nothing
       Just i  => Just (pack (take i cs), pack (drop (S i) cs))

||| Substring between the first '[' and the following ']', if both exist.
export
betweenBrackets : String -> Maybe String
betweenBrackets s =
  let cs = unpack s
  in case elemIndex '[' cs of
       Nothing => Nothing
       Just i =>
         let afterOpen = drop (S i) cs
         in case elemIndex ']' afterOpen of
              Nothing => Nothing
              Just j  => Just (pack (take j afterOpen))

||| Everything after the first '[' (for multi-line array accumulation).
export
afterOpenBracket : String -> String
afterOpenBracket s = pack (drop 1 (dropWhile (/= '[') (unpack s)))

||| Key side of an assignment: strip decoration, lowercase, keep the LAST
||| dotted segment (`security.capabilities` → `capabilities`).
export
keyName : String -> String
keyName raw =
  let kept = pack (filter keep (unpack (toLower raw)))
      segments = splitChars '.' kept
  in case reverse segments of
       (last :: _) => last
       []          => kept
  where
    keep : Char -> Bool
    keep c = isAlphaNum c || c == '.' || c == '_' || c == '-'

||| Strip quotes, backticks and stray punctuation around a scalar.
export
stripScalar : String -> String
stripScalar s =
  let cs = unpack s
      bad = ['"', '\'', '`', ' ', ',', ']']
      fwd = dropWhile (`elem` bad) cs
  in pack (reverse (dropWhile (`elem` bad) (reverse fwd)))

||| A pending multi-line array being accumulated.
private
record Pending where
  constructor MkPending
  pkey : String
  pfile : String
  pbuf : String

||| Extract allow/deny policy values from one file's text.
export
extractPolicy : (path : String) -> (text : String) -> List PolicyValue
extractPolicy path text = snd (foldl step (Nothing, []) (lines text))
  where
    emitKey : String -> String -> String -> List PolicyValue
    emitKey key file body =
      map (\t => MkPolicy key t file) (arrayTokens body)

    emitScalar : String -> String -> String -> List PolicyValue
    emitScalar key file value =
      case nonceToken (stripScalar value) of
        Just t  => [MkPolicy key t file]
        Nothing => []

    handleValue : String -> String -> List PolicyValue -> (Maybe Pending, List PolicyValue)
    handleValue key value acc0 =
      let v = trim value
      in if isInfixOf "[" v
           then case betweenBrackets v of
                  Just body => (Nothing, acc0 ++ emitKey key path body)
                  Nothing   => (Just (MkPending key path v), acc0)
           else (Nothing, acc0 ++ emitScalar key path v)

    step : (Maybe Pending, List PolicyValue) -> String -> (Maybe Pending, List PolicyValue)
    step (Nothing, acc) raw =
      let line = trim raw
      in case breakOn '=' line of
           Nothing => (Nothing, acc)
           Just (lhs, rhs) =>
             let key = keyName lhs
             in if isPolicyKey key
                  then handleValue key rhs acc
                  else (Nothing, acc)
    step (Just pending, acc) raw =
      let line = trim raw
          buf' = pbuf pending ++ " " ++ line
      in case elemIndex ']' (unpack line) of
           Just _  => (Nothing, acc ++ emitKey (pkey pending) (pfile pending)
                                        (afterOpenBracket buf'))
           Nothing => (Just ({ pbuf := buf' } pending), acc)
