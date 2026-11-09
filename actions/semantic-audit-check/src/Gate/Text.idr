-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- Gate.Text — dependency-free text normalisation shared by the gates.
--
-- No regexes (Idris2 base has none): tokenising and lowercasing are done by
-- hand over unpacked characters. Every function here is pure and total.

module Gate.Text

import Data.List
import Data.String

%default total

||| Characters kept inside a token. Everything else is a delimiter.
export
isTokenChar : Char -> Bool
isTokenChar c = isAlphaNum c || c == '_' || c == '-' || c == '.' || c == '/'

||| Lowercase a string.
export
lower : String -> String
lower = toLower

||| Collapse every run of characters outside the token alphabet into a single
||| space, then split into tokens, then lowercase each token.
export
tokenize : String -> List String
tokenize s =
  let chars = map (\c => if isTokenChar c then c else ' ') (unpack s)
  in words (pack chars)

||| Collapse whitespace, drop meaningless trailing punctuation, lowercase.
||| Two policy lines that differ only in these ways compare equal.
export
normalizeLine : String -> String
normalizeLine s =
  let collapsed = unwords (words s)
      cs = reverse (unpack collapsed)
      dropped = dropWhile (`elem` trailing) cs
  in toLower (pack (reverse dropped))
  where
    trailing : List Char
    trailing = [',', ';', '{', '}', '[', ']']

||| Number of whitespace-separated words.
export
wordCount : String -> Nat
wordCount s = length (words s)


||| Split a string on every occurrence of a delimiter character. Total.
||| Consecutive delimiters yield empty pieces; callers that care should
||| filter them out (all our uses do).
export
splitChars : Char -> String -> List String
splitChars c s =
  let (acc, cur) = foldl step ([], []) (unpack s)
  in reverse (pack (reverse cur) :: acc)
  where
    step : (List String, List Char) -> Char -> (List String, List Char)
    step (acc, cur) d = if d == c
                          then (pack (reverse cur) :: acc, [])
                          else (acc, d :: cur)

||| Case-insensitive containment of a needle in a haystack.
export
containsToken : String -> String -> Bool
containsToken hay needle = isInfixOf (toLower needle) (toLower hay)

||| True when the line is blank or a comment in any surface the gates read
||| (`#`, `//`, `;`).
export
isCommentLine : String -> Bool
isCommentLine s =
  let t = trim s
  in t == "" || isPrefixOf "#" t || isPrefixOf "//" t || isPrefixOf ";" t
