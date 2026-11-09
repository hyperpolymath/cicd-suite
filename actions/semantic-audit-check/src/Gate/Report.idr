-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- Gate.Report — one diagnostic accumulator, one rendering format.
--
-- Both gates print GitHub Actions workflow commands (::error:: ::warning::
-- ::notice::) so failures surface as annotations, then a single verdict
-- line, then an optional `status=…` line appended to $GITHUB_OUTPUT.
-- Exit-code authority lives here and nowhere else:
--   0 = the checks ran and found no defect
--   1 = the checks ran and found at least one defect
--   2 = NO CHECK WAS PERFORMED (callers map this to status=not_run)

module Gate.Report

import Data.List
import Data.String
import System
import System.File.ReadWrite

%default total

||| Accumulated diagnostics. Constructors accumulate with snoc-style consing
||| (most recent first); rendering reverses once at the end.
public export
record Diag where
  constructor MkDiag
  errors   : List String
  warnings : List String
  notices  : List String

namespace Diag
  export
  empty : Diag
  empty = MkDiag [] [] []

  export
  error : Diag -> String -> Diag
  error d msg = { errors := msg :: errors d } d

  export
  warning : Diag -> String -> Diag
  warning d msg = { warnings := msg :: warnings d } d

  export
  notice : Diag -> String -> Diag
  notice d msg = { notices := msg :: notices d } d

  export
  isFail : Diag -> Bool
  isFail d = not (null (errors d))

  ||| The status token written to $GITHUB_OUTPUT / printed for the wrapper.
  export
  status : Diag -> String
  status d = if isFail d then "failed" else "passed"

  export
  defectCount : Diag -> Nat
  defectCount d = length (errors d)

||| Render the diagnostics and verdict. `gate` is the short gate name used in
||| every line ("prat-check" / "semantic-audit-check").
export
render : (gate : String) -> Diag -> List String
render gate d =
  let errs  = joinBy "\n" (map (\m => "::error::" ++ gate ++ ": " ++ m) (reverse (errors d)))
      warns = joinBy "\n" (map (\m => "::warning::" ++ gate ++ ": " ++ m) (reverse (warnings d)))
      notes = joinBy "\n" (map (\m => "::notice::" ++ gate ++ ": " ++ m) (reverse (notices d)))
      body  = filter (/= "") [errs, warns, notes]
      verdict = if isFail d
                  then gate ++ ": FAILED — " ++ show (defectCount d) ++ " defect(s) found."
                  else gate ++ ": passed."
  in body ++ [verdict]

||| Print the rendered report to stdout.
export
printReport : (gate : String) -> Diag -> IO ()
printReport gate d =
  putStrLn (unlines (render gate d))

||| Append `status=<status>` to the GitHub output file, when one is supplied.
export
emitStatus : (maybeOutput : Maybe String) -> (status : String) -> IO ()
emitStatus Nothing _ = pure ()
emitStatus (Just path) s = do
  Right () <- appendFile path ("status=" ++ s ++ "\n")
    | Left _ => do
        putStrLn ("::warning::could not append status to " ++ path)
        pure ()
  pure ()
