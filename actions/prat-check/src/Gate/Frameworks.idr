-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- Gate.Frameworks — what counts as property-based testing, per ecosystem.
--
-- Two independent signals, both plain substring scans (no regexes):
--
--   * declaration: a manifest declares a known PBT dependency
--     (Cargo.toml, package.json, pyproject.toml, go.mod, …)
--   * marker: a source file contains a token a generator/property harness
--     emits (proptest!, @given, fc.assert, quick.Check, …)
--
-- A declared framework with zero markers is a defect (the dependency was
-- added and no property was ever written). No signal anywhere is a defect
-- unless the caller relaxes it with REQUIRE_PROPERTIES=false. Markers carry
-- more weight than declarations: several runtimes ship PBT in the standard
-- library (Go's testing/quick), which no manifest can declare.
--
-- Scoping: markers are either global (unambiguous in any source file) or
-- bound to a set of file extensions, so that e.g. Python's ubiquitous
-- `@property` is never read as JVM jqwik.

module Gate.Frameworks

import Data.String

%default total

public export
record Ecosystem where
  constructor MkEco
  ||| Short identifier used in diagnostics and in the test runner plan.
  name : String

||| Every ecosystem the gate recognises. Detection tables live below; the
||| names are matched against the manifest tables for the executed-test plan.
public export
ecosystems : List Ecosystem
ecosystems =
  [ MkEco "rust", MkEco "python", MkEco "js", MkEco "go", MkEco "jvm"
  , MkEco "haskell", MkEco "ocaml", MkEco "elixir", MkEco "erlang"
  , MkEco "ruby", MkEco "swift", MkEco "scala", MkEco "dotnet"
  ]

||| Does this manifest path belong to the named ecosystem?
public export
isManifestFor : (eco : String) -> (relLower : String) -> (base : String) -> Bool
isManifestFor eco relLower base =
  case eco of
    "rust"    => base == "cargo.toml"
    "python"  => base == "pyproject.toml" || base == "setup.cfg" || base == "setup.py"
                 || base == "pipfile" || isPrefixOf "requirements" base || base == "poetry.lock"
    "js"      => base == "package.json"
    "go"      => base == "go.mod"
    "jvm"     => base == "pom.xml" || base == "build.gradle" || base == "build.gradle.kts"
                 || isPrefixOf "build" base && isSuffixOf ".gradle" base
    "haskell" => base == "stack.yaml" || base == "package.yaml" || isSuffixOf ".cabal" base
    "ocaml"   => isSuffixOf ".opam" base || base == "dune-project"
    "elixir"  => base == "mix.exs"
    "erlang"  => base == "rebar.config"
    "ruby"    => base == "gemfile"
    "swift"   => base == "package.swift"
    "scala"   => base == "build.sbt"
    "dotnet"  => isSuffixOf ".csproj" base || isSuffixOf ".fsproj" base
    _         => False

||| Dependency tokens that declare a PBT framework in a manifest.
public export
depTokens : (eco : String) -> List String
depTokens eco =
  case eco of
    "rust"    => ["proptest", "quickcheck", "bolero"]
    "python"  => ["hypothesis", "schemathesis"]
    "js"      => ["fast-check", "jsverify", "testcheck"]
    "go"      => ["pgregory.net/rapid", "gopter", "testing/quick"]
    "jvm"     => ["jqwik", "junit-quickcheck", "com.pholser.junit"]
    "haskell" => ["quickcheck", "hedgehog", "hspec-quickcheck"]
    "ocaml"   => ["qcheck"]
    "elixir"  => ["stream_data", "excheck"]
    "erlang"  => ["proper", "triq"]
    "ruby"    => ["rantly", "prop_check", "propcheck"]
    "swift"   => ["swiftcheck"]
    "scala"   => ["scalacheck"]
    "dotnet"  => ["fscheck", "xunit.quickcheck"]
    _         => []

||| Marker tokens: unambiguous in any source file.
public export
globalMarkers : List String
globalMarkers =
  [ "proptest!", "#[quickcheck]", "use proptest"
  , "from hypothesis", "import hypothesis", "@given"
  , "fc.assert", "fc.property"
  , "rapid.check", "gopter", "quick.check"
  , "qcheck"
  , "stream_data"
  , "prop_"
  , "scalacheck", "fscheck", "swiftcheck"
  , "rantly", "propcheck"
  ]

||| Marker tokens bound to file extensions (comma-separated list of
||| extensions without the dot) so overloaded words do not leak across
||| ecosystems (Python's @property is not jqwik's).
public export
scopedMarkers : List (List String, List String)
scopedMarkers =
  [ (["hs", "lhs"],          ["forall ", "property $"])
  , (["java", "kt", "kts"],  ["@property", "@quickcheck", "@forall"])
  , (["ex", "exs"],          ["check all", "property \""])
  , (["erl", "hrl"],         ["?forall", "proper:", "triq:"])
  , (["rb"],                 ["property \""])
  , (["scala", "sc"],        ["forall"])
  , (["fs", "fsx", "cs"],    ["[property]"])
  , (["go"],                 ["quick.check"])
  ]

||| Test/source extensions worth reading for markers at all.
public export
sourceExtensions : List String
sourceExtensions =
  [ "rs", "hs", "lhs", "py", "pyw", "js", "jsx", "mjs", "cjs", "ts", "tsx"
  , "go", "java", "kt", "kts", "ml", "mli", "re", "rei", "ex", "exs"
  , "erl", "hrl", "rb", "swift", "scala", "sc", "cs", "fs", "fsx"
  , "idr", "zig", "jl", "scm", "rkt", "c", "cc", "cpp", "cxx", "h", "hpp"
  ]
