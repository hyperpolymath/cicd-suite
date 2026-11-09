-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- Gate.Tree — walk the working tree once, without git, without regexes.
--
-- The gates must behave identically inside and outside a git checkout, so
-- this is a plain filesystem walk with a VCS/build-output blocklist rather
-- than `git ls-files`. Directories that cannot be read are reported as
-- warnings, never silently skipped; the root itself is handled by the
-- caller (an unreadable root is "NO CHECK WAS PERFORMED").

module Gate.Tree

import Data.List
import Data.String
import System.Directory
import System.File.Meta
import Gate.Text

%default total

public export
record FoundFile where
  constructor MkFound
  ||| Path relative to the walked root, forward slashes, no leading "./".
  rel : String
  ||| Path as handed to the filesystem ("./a/b" or "a/b").
  abs : String

||| Join two path fragments with exactly one separator.
export
joinPath : String -> String -> String
joinPath "" y = y
joinPath x y = if isSuffixOf "/" x then x ++ y else x ++ "/" ++ y

||| Directory names this walker never descends into. Note that dot-directories
||| in general are NOT excluded: the gates audit `.machine_readable`.
export
isBlockedDir : String -> Bool
isBlockedDir name =
  let n = toLower name
  in n == ".git" || n == ".hg" || n == ".svn"
     || n == "node_modules" || n == "target" || n == "build" || n == "dist"
     || n == "out" || n == "vendor" || n == ".venv" || n == "venv"
     || n == "__pycache__" || n == ".zig-cache" || n == "zig-cache"
     || n == ".lake" || n == ".cicd-suite" || n == ".idea" || n == ".vscode"

public export
record WalkResult where
  constructor MkWalk
  files    : List FoundFile
  warnings : List String

||| Merge two walk results.
export
mkWalk : List FoundFile -> List String -> WalkResult
mkWalk = MkWalk

||| Recursion depth ceiling. A symlink cycle below the root must not hang the
||| gate; legitimate trees are far shallower than this.
maxDepth : Nat
maxDepth = 24

partial
walkRel : (root : String) -> (rel : String) -> (depth : Nat) -> IO WalkResult
walkRel root rel depth = do
  let dir = if rel == "" then root else joinPath root rel
  Right entries <- listDir dir
    | Left err => pure (MkWalk [] ["could not read directory " ++ dir ++ " (" ++ show err ++ ")"])
  results <- traverse (probeEntry root rel depth) entries
  pure (foldl mergeResults (MkWalk [] []) results)
  where
    mergeResults : WalkResult -> WalkResult -> WalkResult
    mergeResults (MkWalk fs ws) (MkWalk fs' ws') = MkWalk (fs ++ fs') (ws ++ ws')

    probeEntry : (String) -> (String) -> (Nat) -> String -> IO WalkResult
    probeEntry root rel depth name = do
      let rel' = if rel == "" then name else rel ++ "/" ++ name
          abs' = joinPath root rel'
      if isBlockedDir name
        then pure (MkWalk [] [])
        else do
          Right sub <- listDir abs'
            | Left err =>
                case show err of
                  "Permission Denied" =>
                    pure (MkWalk [] ["could not read directory " ++ abs' ++ " (permission denied)"])
                  _ =>
                    if depth >= maxDepth
                      then pure (MkWalk [] ["skipping " ++ abs' ++ " (depth exceeds " ++ show maxDepth ++ ")"])
                      else pure (MkWalk [MkFound rel' abs'] [])
          if depth + 1 > maxDepth
            then pure (MkWalk [] ["skipping " ++ abs' ++ " (depth exceeds " ++ show maxDepth ++ ")"])
            else walkRel root rel' (depth + 1)

||| Strip a leading "./" from a walked path, if present.
export
stripDot : String -> String
stripDot s = if isPrefixOf "./" s then pack (drop 2 (unpack s)) else s

||| Walk `root` and return the regular files found, sorted by relative path
||| for deterministic output.
partial
export
walkTree : (root : String) -> IO WalkResult
walkTree root = do
  res <- walkRel root "" 0
  let sorted = sortBy (\a, b => compare (rel a) (rel b)) (files res)
      clean  = map stripFile sorted
  pure ({ files := clean } res)
  where
    stripFile : FoundFile -> FoundFile
    stripFile f = { rel := stripDot (rel f) } f

||| File extension, lowercased, without the dot. Empty when none.
export
extOf : String -> String
extOf path =
  let base = reverse (unpack path)
      (ext, rest) = span (/= '.') base
  in case rest of
       [] => ""
       _  => toLower (pack (reverse ext))

||| Split a path on single separators.
export
splitPath : String -> List String
splitPath = splitChars '/'

||| Basename, lowercased (for manifest matching).
export
baseOf : String -> String
baseOf path =
  case reverse (splitPath path) of
    (b :: _) => toLower b
    []       => toLower path
