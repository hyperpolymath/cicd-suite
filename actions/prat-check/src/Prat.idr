-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- prat-check — does this repository actually have property-based testing?
--
-- What this gate does, honestly:
--
--   DETECT   scan manifests for a declared property-testing framework
--            (proptest/QuickCheck/hypothesis/fast-check/jqwik/…); scan
--            source files for property-test markers.
--   FAIL     when a framework is declared but zero property tests exist, or
--            when REQUIRE_PROPERTIES=true and there is no evidence at all.
--   RUN      only with RUN_TESTS=true: one conventional test command per
--            detected ecosystem. A missing runner is not_run (exit 2), never
--            a pass; a failing command is a defect (exit 1).
--
-- What it does NOT do: prove the properties are meaningful, count coverage,
-- or substitute for the repository's own test CI. Presence of PBT is an
-- honest, checkable floor — not a ceiling on assurance.
--
-- Exit codes: 0 passed · 1 defect(s) · 2 NO CHECK WAS PERFORMED.

module Prat

import Data.List
import Data.Maybe
import Data.String
import Gate.Frameworks
import Gate.Report
import Gate.Text
import Gate.Tree
import System
import System.Directory
import System.File
import System.File.Meta
import System.File.ReadWrite

%default total

record Options where
  constructor MkOptions
  requireProperties : Bool
  runTests : Bool
  githubOutput : Maybe String

partial
parseArgs : List String -> Options
parseArgs = go (MkOptions True False Nothing)
  where
    partial
    go : Options -> List String -> Options
    go opts [] = opts
    go opts (a :: b :: rest) =
      case a of
           "--require-properties" => go ({ requireProperties := "false" /= b } opts) rest
           "--run-tests"          => go ({ runTests := "true" == b } opts) rest
           "--github-output"      => go ({ githubOutput := Just b } opts) rest
           _                      => go opts (b :: rest)
    go opts (_ :: []) = opts

||| Read a text file, treating a read failure as data (not a crash).
partial
readFileMaybe : String -> IO (Maybe String)
readFileMaybe path = do
  Right content <- readFile path
    | Left _ => pure Nothing
  pure (Just content)

||| Lowercased file contents for case-insensitive scanning, or Nothing when
||| the file cannot be read.
partial
readLower : String -> IO (Maybe String)
readLower path = map (map toLower) (readFileMaybe path)

||| Which ecosystem does this manifest belong to? (First match wins;
||| one file is one ecosystem for our purposes.)
manifestEcosystem : String -> Maybe String
manifestEcosystem rel =
  let l = toLower (stripDot rel)
      base = baseOf l
  in  findFirst (map name ecosystems) l base
  where
    findFirst : List String -> String -> String -> Maybe String
    findFirst [] _ _ = Nothing
    findFirst (e :: es) l base = if isManifestFor e l base then Just e else findFirst es l base

||| (ecosystem, manifest, matchedTokens) triples whose contents declare a PBT dependency.
partial
declaredFrameworks : List FoundFile -> IO (List (String, String, List String))
declaredFrameworks files = do
  let manifests = mapMaybe (\f => map (\eco => (eco, f)) (manifestEcosystem (rel f))) files
  hits <- traverse check manifests
  pure (mapMaybe id hits)
  where
    partial
    check : (String, FoundFile) -> IO (Maybe (String, String, List String))
    check (eco, f) = do
      Just content <- readLower (abs f)
        | Nothing => pure Nothing
      let matched = filter (\tok => isInfixOf tok content) (depTokens eco)
      pure (if null matched
              then Nothing
              else Just (eco, rel f, matched))

||| Marker evidence: (file, token) pairs, capped in number by the caller.
partial
markerHits : List FoundFile -> IO (List (String, String))
markerHits files = do
  let sources = filter (\f => elem (extOf (rel f)) sourceExtensions) files
  hits <- traverse scanOne sources
  pure (concat hits)
  where
    partial
    scanOne : FoundFile -> IO (List (String, String))
    scanOne f = do
      Just content <- readLower (abs f)
        | Nothing => pure []
      let ext : String = extOf (rel f)
          scoped : List String = concat (map (\(_, b) => b) (filter (\(exts, _) : (List String, List String) => elem ext exts) scopedMarkers))
          tokens : List String = globalMarkers ++ scoped
      pure (map (\tok => (rel f, tok)) (filter (\tok => isInfixOf tok content) tokens))

||| One conventional test command per ecosystem with a declared framework.
||| Returns (failures, missing runners).
partial
runDeclared : (ecos : List String) -> (files : List FoundFile) -> IO (List String, List String)
runDeclared ecos files = do
  results <- traverse runOne ecos
  pure (concat (map (\(a, _) => a) results), concat (map (\(_, b) => b) results))
  where
    allRels : List String
    allRels = map rel files

    commandFor : String -> Maybe String
    commandFor eco =
      case eco of
        "rust"    => Just "cargo test"
        "python"  => Just "python3 -m pytest -q"
        "js"      => Just "npm test"
        "go"      => Just "go test ./..."
        "jvm"     => if any (isSuffixOf "pom.xml") allRels then Just "mvn -q -B test" else Just "gradle test"
        "haskell" => if any (isSuffixOf "stack.yaml") allRels then Just "stack test" else Just "cabal test"
        "ocaml"   => Just "dune runtest"
        "elixir"  => Just "mix test"
        "erlang"  => Just "rebar3 eunit"
        "swift"   => Just "swift test"
        "scala"   => Just "sbt test"
        "dotnet"  => Just "dotnet test"
        _         => Nothing

    partial
    runOne : String -> IO (List String, List String)
    runOne eco =
      case commandFor eco of
        Nothing => do
          putStrLn ("prat-check: RUN_TESTS=true — no conventional test command for ecosystem '"
                    ++ eco ++ "'; skipping (detection-only for this ecosystem).")
          pure ([], [])
        Just cmd => do
          putStrLn ("prat-check: running '" ++ cmd ++ "' …")
          rc <- system ("timeout 900 " ++ cmd)
          case rc of
            0          => pure ([], [])
            126        => pure ([], [eco])
            127        => pure ([], [eco])
            -1         => pure ([], [eco])
            n          => pure (["test command failed for ecosystem '" ++ eco ++ "': "
                                 ++ cmd ++ " (exit " ++ show n ++ ")"], [])


partial
main : IO ()
main = do
  args <- getArgs
  let opts = parseArgs args
  let githubOutput = githubOutput opts

  Right rootListing <- listDir "."
    | Left err => do
        emitStatus githubOutput "not_run"
        putStrLn ("prat-check: NO CHECK WAS PERFORMED — cannot enter the working directory (" ++ show err ++ ").")
        exitWith (ExitFailure 2)

  walk <- walkTree "."
  let files = walk.files
      gateWarnings = walk.warnings
  putStrLn ("prat-check: " ++ show (length files) ++ " file(s) in working tree; scanning manifests and sources…")

  declared <- declaredFrameworks files
  let declaredEcos = nub (map (\(a, _, _) => a) declared)
  let declaredToks = nub (concat (map (\(_, _, ts) => ts) declared))
  putStrLn ("prat-check: PBT framework declared in "
            ++ show (length declared) ++ " manifest(s)"
            ++ (if null declaredEcos then "" else " (" ++ unwords (sort declaredEcos) ++ ")"))

  hits <- markerHits files
  putStrLn ("prat-check: " ++ show (length hits) ++ " property-test marker(s) in "
            ++ show (length (nub (map (\(a, _) => a) hits))) ++ " file(s)")

  let diagWarnings : Diag = foldl Diag.warning Diag.empty gateWarnings

  let declaredEcos : List String = nub (sort (map (\(a, _, _) => a) declared))
      declaredPaths : List String = nub (sort (map (\(_, b, _) => b) declared))
      defMissingFramework : Bool = not (null declared) && null hits
      noEvidence : Bool = null declared && null hits

  let d1 : Diag = if defMissingFramework
             then Diag.error diagWarnings
               ("PBT framework declared in " ++ unwords declaredPaths
                ++ " but no property tests were found in any source file (declared: "
                ++ unwords declaredToks ++ "; no proptest!, @given, fc.assert, quick.check or scoped markers)."
                ++ " Write property tests for the declared framework, or remove the dependency.")
             else diagWarnings

  let d2 : Diag = if noEvidence
             then if requireProperties opts
               then Diag.error d1
                 ("no property-based testing detected: no PBT framework declared in any"
                  ++ " manifest (Cargo.toml, package.json, pyproject.toml, go.mod, …) and no"
                  ++ " property-test markers (proptest!, @given, fc.assert, quick.check, …) in"
                  ++ " any source file. Estate policy expects property tests; set"
                  ++ " require_properties: false to demote this to advisory.")
               else Diag.notice d1
                 "no property-based testing evidence found (require_properties=false)."
             else Diag.notice d1
               ("property-based testing detected: " ++ show (length hits)
                ++ " marker(s) across " ++ show (length (nub (map (\(a, _) => a) hits))) ++ " file(s).")

  -- sample of markers, capped, so the log shows where the evidence lives
  let d3 : Diag = foldl Diag.notice d2 (map (\(f, t) => "marker: " ++ f ++ "  (" ++ t ++ ")")
                                     (take 10 hits))

  -- optional execution of declared frameworks' test commands
  let d4 = d3
  runRes <- if runTests opts
              then runDeclared declaredEcos files
              else pure ([], [])
  let (runnerFails, runnerMissing) = runRes
  let d5 : Diag = foldl Diag.error d4 runnerFails
  let d6 = if null runnerMissing
             then d5
             else Diag.warning d5
               ("RUN_TESTS=true but runner(s) not on PATH: "
                ++ unwords runnerMissing ++ " — those suites were NOT executed.")

  if not (null runnerMissing) && null (errors d6) && runTests opts
    then do
      let dNotRun = Diag.warning d6 "at least one requested test runner was missing; no green claim is made."
      printReport "prat-check" dNotRun
      emitStatus githubOutput "not_run"
      putStrLn "prat-check: NO CHECK WAS PERFORMED — requested test runner(s) missing."
      exitWith (ExitFailure 2)
    else do
      printReport "prat-check" d6
      emitStatus githubOutput (Diag.status d6)
      if Diag.isFail d6
        then exitWith (ExitFailure 1)
        else exitSuccess
