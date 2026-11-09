-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- semantic-audit-check — deterministic semantic audit of repository metadata.
--
-- The AI-powered version of this gate does not exist: cicd-squabbler is a
-- gate-diagnosis engine, not a semantic verifier, and pretending otherwise
-- is how the placeholder shipped "Semantic Audit Passed." unconditionally.
-- This gate is what CAN be checked honestly today, deterministically:
--
--   S1 applicability  any audited artefact present, else not_applicable.
--   S2 core set       the core descriptiles (STATE/META/ECOSYSTEM.a2ml) exist
--                     in a recognised location and are not empty; the six
--                     known names are located; surfaces are reported.
--   S3 policy         contradictions (a token allowed in one place and
--                     banned in another) and verbatim restatement of policy
--                     lines across descriptiles and K9 contracts — the
--                     "restated contractile" contamination class from
--                     DESCRIPTILE-SPEC v0.1.1 (RULING PENDING, detected
--                     only at the deterministic level).
--   S4 completeness   every *.k9.ncl under the tree declares the five
--                     required top-level fields of K9 contract v1.0.0
--                     (schema_version, component_type, semantics, security,
--                     side_effects). Grammar and typechecking remain the
--                     deed-lint / k9-validate lanes.
--   S5 CLAUDE.md      when present at the root: non-empty, has a top-level
--                     heading, balanced code fences, no merge markers, no
--                     unresolved template placeholders.
--
-- Out of scope for this pass (presence is reported, never judged):
-- anchors (ANCHOR family is not a descriptile; its spec is unwritten),
-- bot_directives (no ratified schema), OED spelling/grammar (that needs
-- judgement, not detection), LLM review of any kind.
--
-- Exit codes: 0 passed/not_applicable · 1 defect(s) · 2 NO CHECK WAS PERFORMED.

module SemanticAudit

import Data.List
import Data.String
import Data.Nat
import Gate.A2ml
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
  githubOutput : Maybe String

partial
parseArgs : List String -> Options -> Options
parseArgs [] opts = opts
parseArgs (a :: b :: rest) opts =
  case a of
       "--github-output" => parseArgs rest ({ githubOutput := Just b } opts)
       _                  => parseArgs (b :: rest) opts
parseArgs (_ :: []) opts = opts

partial
readArgs : List String -> Options
readArgs args = parseArgs args (MkOptions Nothing)

||| List set difference (order-preserving).
diffList : Eq a => List a -> List a -> List a
diffList xs ys = filter (\x => not (elem x ys)) xs

||| Split a string at the FIRST occurrence of any of the delimiter
||| characters, if any is present.
breakOnAny : List Char -> String -> Maybe (String, String)
breakOnAny ds s = go (unpack s) []
  where
    go : List Char -> List Char -> Maybe (String, String)
    go [] _ = Nothing
    go (c :: rest) acc = if elem c ds
        then Just (pack (reverse acc), pack rest)
        else go rest (c :: acc)

||| The six descriptile stems, lowercased, without extension.
descriptorStems : List String
descriptorStems = ["state", "meta", "ecosystem", "agentic", "neurosym", "playbook"]

||| The three REQUIRED core descriptiles.
coreStems : List String
coreStems = ["state", "meta", "ecosystem"]

||| Recognised descriptor locations, in preference order (spec: canonical
||| first, then the measured-but-legacy `6a2`, then bare `.machine_readable/`).
descriptorDirs : List String
descriptorDirs = [".machine_readable/descriptiles/", ".machine_readable/6a2/"]

partial
readFileMaybe : String -> IO (Maybe String)
readFileMaybe path = do
  Right content <- readFile path
    | Left _ => pure Nothing
  pure (Just content)

||| File stem (basename without extension), lowercased.
stemOf : String -> String
stemOf rel =
  let base = baseOf rel
      cs = reverse (unpack base)
  in case elemIndex '.' cs of
       Nothing => base
       Just i  => pack (reverse (drop (S i) cs))

||| Directory segments of a relative path.
dirsOf : String -> List String
dirsOf rel =
  let parts = splitChars '/' rel
  in if length parts > 1 then reverse (drop 1 (reverse parts)) else []

||| Files directly inside a directory (not recursive).
directChildren : String -> List String -> List String
directChildren dirPrefix rels =
  filter (\r => isPrefixOf dirPrefix r
             && not (any (== '/') (unpack (pack (drop (length (unpack dirPrefix)) (unpack r)))))) rels

||| All files under a directory prefix.
underDir : String -> List String -> List String
underDir dirPrefix rels = filter (isPrefixOf dirPrefix) rels

||| First non-comment, non-blank line.
meaningfulLine : List String -> Maybe String
meaningfulLine [] = Nothing
meaningfulLine (l :: ls) =
  if isCommentLine l then meaningfulLine ls else Just (trim l)

||| Count of meaningful (non-comment, non-blank) lines.
meaningCount : String -> Nat
meaningCount text = length (filter (not . isCommentLine) (lines text))

||| Normalisation used by the restatement check: lowercase, whitespace-
||| collapsed, trailing punctuation dropped.
normPolicyLine : String -> String
normPolicyLine = normalizeLine

||| Does the line mention a policy-bearing keyword?
hasPolicyTrigger : String -> Bool
hasPolicyTrigger l =
  let t = toLower l
      triggers = [ "banned", "forbid", "prohibit", "deny", "denylist", "blacklist"
                 , "blocklist", "disallow", "allowlist", "whitelist", "sanctioned"
                 , "invariant", "forbidden", "permitted" ]
  in any (\trt => isInfixOf trt t) triggers

||| Lines worth comparing across files: policy-bearing, long enough to carry
||| a real statement, not a stamp, not a date line.
isComparablePolicyLine : String -> Bool
isComparablePolicyLine raw =
  let n = normPolicyLine raw
  in length n >= 40 && wordCount n >= 6 && hasPolicyTrigger n
     && not (isPrefixOf "spdx" n) && not (isInfixOf "example.com" n)
     && not (isInfixOf "copyright" n)

||| First Just in a list, if any.
firstJust : List (Maybe a) -> Maybe a
firstJust [] = Nothing
firstJust (Just x :: _) = Just x
firstJust (Nothing :: xs) = firstJust xs

||| Fold an IO action over a list, accumulating a Diag.
partial
foldlIO : b -> List a -> (a -> b -> IO b) -> IO b
foldlIO acc [] f = pure acc
foldlIO acc (x :: xs) f = do
  acc' <- f x acc
  foldlIO acc' xs f

||| Does the text contain a top-level field declaration for `key`?
||| (`key` at line start, up to `=` or `:` — Nickel and a2ml both.)
hasTopLevelField : String -> String -> Bool
hasTopLevelField key text =
  any lineHasKey (lines text)
  where
    lineHasKey : String -> Bool
    lineHasKey raw =
      let t = toLower (trim raw)
      in case breakOnAny ['=', ':'] t of
           Nothing => False
           Just (lhs, _) => trim lhs == key


||| Duplicate policy lines across files: (normalised line, fileA, fileB, raw).
findDuplicates : List (String, String, String) -> List (String, String, String, String)
findDuplicates entries =
  let pairs = [ (n1, a, b, r1)
              | (n1, f1, r1) <- entries
              , (n2, f2, _) <- entries
              , n1 == n2 && f1 /= f2
              , let (a, b) = if f1 <= f2 then (f1, f2) else (f2, f1)
              ]
  in nub pairs

partial
surfaceNote : String -> IO (Maybe String)
surfaceNote rel = do
  Just t <- readFileMaybe rel
    | Nothing => pure Nothing
  pure (case meaningfulLine (lines t) of
          Nothing => Nothing
          Just l  =>
            if isPrefixOf "(" l
              then Just (rel ++ ": s-expression surface (sanctioned but non-canonical, DESCRIPTILE-SPEC v0.1.1)")
              else if isPrefixOf "@" l && stemOf rel /= "state"
                then Just (rel ++ ": @-block surface is only sanctioned for STATE.a2ml")
                else Nothing)

||| Read a descriptor and report whether it carries any meaningful content.
partial
checkDescriptor : String -> IO (Maybe (String, String))
checkDescriptor r = do
  Just t <- readFileMaybe r
    | Nothing => pure (Just (r, "unreadable"))
  pure (if meaningCount t == 0 then Just (r, "empty or comments-only") else Nothing)

||| Content lines of a Markdown file: skips blanks and HTML comments —
||| keeps `#` heading lines, which Markdown means literally.
mdMeaningfulLines : List String -> List String
mdMeaningfulLines ls = filter isMdContent ls
  where
    isMdContent : String -> Bool
    isMdContent l =
      let t = trim l
      in t /= "" && not (isPrefixOf "<!--" t)

||| S2 — REQUIRED core descriptiles present and non-empty.
partial
s2CoreSet : Diag -> Maybe String -> List String -> IO Diag
s2CoreSet d0 locOpt descriptorsPresent = case locOpt of
  Nothing => pure d0
  Just loc => do
    let foundStems : List String = map stemOf descriptorsPresent
        missing : List String = filter (\s => not (elem s foundStems)) coreStems
    empties <- traverse checkDescriptor descriptorsPresent
    let d1w : Diag = foldl Diag.error d0
              (map (\s => "core descriptile missing in " ++ loc ++ ": "
                           ++ toUpper s ++ ".a2ml — the repository describes itself nowhere.")
                   missing)
    let errStrs : List String = map (\(f, msg) => f ++ ": " ++ msg) (mapMaybe id empties)
    pure (foldl Diag.error d1w errStrs)

||| Surface notes (advisory; the surface ruling is still pending).
partial
surfaceNotes : Diag -> Maybe String -> List String -> IO Diag
surfaceNotes d1 locOpt descriptorsPresent = case locOpt of
  Nothing => pure d1
  Just loc => do
    notes <- traverse surfaceNote descriptorsPresent
    pure (foldl Diag.notice d1 (mapMaybe id notes))

||| S3 — policy coherence across descriptiles and contracts.
partial
s3Policy : Diag -> List String -> List String -> IO Diag
s3Policy d2 rels descriptorsPresent = do
  let policyFiles : List String = nub (sort (descriptorsPresent
            ++ filter (\r => isSuffixOf ".k9.ncl" (toLower r)) rels
            ++ filter (\r => any (\seg => seg == "contractiles") (dirsOf r)
                          && (isSuffixOf ".ncl" (toLower r))) rels))
  policyContents <- traverse (\r => map (map (\t => (r, t))) (readFileMaybe r)) policyFiles
  let policyTexts : List (String, String) = mapMaybe id policyContents
  let unreadable : List String = diffList policyFiles (map (\(a, _) => a) policyTexts)
  let d3a : Diag = foldl Diag.warning d2 (map (\r => "could not read " ++ r ++ " (skipped for policy checks)") unreadable)
  let policies : List PolicyValue = concatMap (\(r, t) => extractPolicy r t) policyTexts
  let allows : List PolicyValue = filter (\p => elem p.key allowKeys) policies
      denies : List PolicyValue = filter (\p => elem p.key denyKeys) policies
  let contradictionPairs : List (String, String, String) =
        nub [ (a.token, f1, f2)
            | a <- allows, d <- denies
            , a.token == d.token
            , let (f1, f2) = if a.file <= d.file then (a.file, d.file) else (d.file, a.file)
            ]
  let d3b : Diag = foldl Diag.error d3a
        (map (\(t, f1, f2) => "contradictory policy for '" ++ t ++ "': allowed in "
                              ++ f1 ++ " but banned in " ++ f2
                              ++ " — one of these statements is stale.")
             (take 20 (nub contradictionPairs)))
  let d3c : Diag = if length contradictionPairs > 20
              then Diag.notice d3b (show (minus (length contradictionPairs) 20) ++ " more contradiction(s) not shown.")
              else d3b
  let comparableLines : List (String, String, String) =
        concatMap (\(r, t) =>
          map (\l => (normPolicyLine l, r, l))
              (filter isComparablePolicyLine (lines t)))
          policyTexts
  let dups : List (String, String, String, String) = findDuplicates comparableLines
  let d3d : Diag = foldl Diag.error d3c
        (map (\(n, f1, f2, l) => "policy restated verbatim in " ++ f1 ++ " and " ++ f2
                               ++ ": \"" ++ pack (take 100 (unpack n)) ++ "\" — a descriptile must reference, never copy, a contractile clause.")
             (take 15 dups))
  pure (if length dups > 15
          then Diag.notice d3d (show (minus (length dups) 15) ++ " more restated line(s) not shown.")
          else d3d)

||| S4 — K9 contract envelope fields.
partial
s4K9 : Diag -> List String -> IO Diag
s4K9 d4 rels = do
  let k9Files : List String = filter (\r => isSuffixOf ".k9.ncl" (toLower r)) rels
      skippedFixture : List String = filter (\r => any (\seg => elem seg ["example", "examples", "template", "templates", "test", "tests", "fixtures"]) (dirsOf r)) k9Files
      coordinate : List String = filter (\r => baseOf r == "coordination.k9") k9Files
      auditable : List String = diffList (diffList k9Files skippedFixture) coordinate
  let requiredFields : List String = ["schema_version", "component_type", "semantics", "security", "side_effects"]
  d5 <- foldlIO d4 auditable (\r, acc => do
          Just t <- readFileMaybe r
            | Nothing => pure (Diag.warning acc ("could not read " ++ r ++ " (skipped for K9 field check)"))
          let missing : List String = filter (\k => not (hasTopLevelField k t)) requiredFields
          pure (if null missing
                  then acc
                  else Diag.error acc ("K9 contract " ++ r ++ " is missing required field(s): "
                                       ++ joinBy ", " missing
                                       ++ " (K9 contract v1.0.0; L0-L2 envelope check).")))
  let d6 : Diag = foldl Diag.notice d5
        (map (\r => "coordination.k9 routed, not validated as a contract: " ++ r) coordinate)
  pure (if null skippedFixture
          then d6
          else Diag.notice d6 (show (length skippedFixture) ++ " K9 file(s) under example/template/test directories exempted from field check."))

||| S5 — CLAUDE.md structure (comments, heading, fences, markers).
partial
s5ClaudeMd : Diag -> List String -> IO Diag
s5ClaudeMd d9 claudeRoot = case claudeRoot of
  [] => pure (Diag.notice d9 "no root CLAUDE.md (fine — formatting-check owns the mandate for repos that want one).")
  (r :: _) => do
    Just text <- readFileMaybe r
      | Nothing => pure (Diag.error d9 ("CLAUDE.md could not be read: " ++ r))
    let nonComment : List String = mdMeaningfulLines (lines text)
        hasH1 : Bool = any (\l => isPrefixOf "# " (trim l) || trim l == "#") nonComment
        h1Count : Nat = length (filter (\l => isPrefixOf "# " (trim l)) nonComment)
        fenceCount : Nat = length (filter (\l => isPrefixOf "```" (trim l)) (lines text))
        mergeMarkers : Bool = any (\l => isPrefixOf "<<<<<<<" (trim l) || isPrefixOf ">>>>>>>" (trim l)) (lines text)
        unresolvedPlaceholder : Bool = isInfixOf "{{" text && isInfixOf "}}" text
    let dA : Diag = if null (mdMeaningfulLines (lines text))
                      then Diag.error d9 "CLAUDE.md is empty (only comments/blank lines)."
                      else d9
    let dB : Diag = if hasH1 then dA else Diag.error dA "CLAUDE.md has no top-level heading (expected a line starting with '# ')."
    let dC : Diag = if mergeMarkers then Diag.error dB "CLAUDE.md contains merge-conflict markers." else dB
    let dD : Diag = if mod fenceCount 2 == 1 then Diag.error dC ("CLAUDE.md has unbalanced fenced code blocks (" ++ show fenceCount ++ " fence lines).") else dC
    let dE : Diag = if unresolvedPlaceholder then Diag.error dD "CLAUDE.md contains an unresolved template placeholder ({{ … }})." else dD
    pure (if h1Count > 1 then Diag.warning dE ("CLAUDE.md has " ++ show h1Count ++ " top-level headings; one is the convention.") else dE)

||| S6 — presence-only notices for anchors and bot directives.
s6Presence : Diag -> List String -> Diag
s6Presence d10 rels =
  let botCount : Nat = length (underDir ".machine_readable/bot_directives/" rels)
      anchorCount : Nat = length (underDir ".machine_readable/anchors/" rels) + length (underDir ".machine_readable/anchor/" rels)
      d11 : Diag = if botCount == 0 then d10 else Diag.notice d10 (show botCount ++ " bot_directives file(s) found — presence only; no ratified schema yet, not audited.")
  in if anchorCount == 0 then d11 else Diag.notice d11 (show anchorCount ++ " anchor file(s) found — presence only; the ANCHOR family is not a descriptile and has no normative checks here yet.")

partial
main : IO ()
main = do
  args <- getArgs
  let opts = readArgs args
  let githubOutput = githubOutput opts

  Right _ <- listDir "."
    | Left err => do
        emitStatus githubOutput "not_run"
        putStrLn ("semantic-audit-check: NO CHECK WAS PERFORMED — cannot enter the working directory (" ++ show err ++ ").")
        exitWith (ExitFailure 2)

  walk <- walkTree "."
  let files : List FoundFile = walk.files
      rels : List String = map rel files
      d0 : Diag = foldl Diag.warning Diag.empty walk.warnings
  putStrLn ("semantic-audit-check: " ++ show (length files) ++ " file(s) in working tree; classifying artefacts…")

  -- -------------------------------------------------- S1 applicability
  let descriptorDir : Maybe String = firstJust (map (\d => if any (isPrefixOf d) rels then Just d else Nothing) descriptorDirs)
  let bareSix : List String = filter (\r => elem (stemOf r) descriptorStems && isSuffixOf ".a2ml" (toLower r))
                       (directChildren ".machine_readable/" rels)
  let hasBareSix : Bool = not (null bareSix)
  let locOpt : Maybe String = case descriptorDir of
                                Just d  => Just d
                                Nothing => if hasBareSix then Just ".machine_readable/" else Nothing
  let descriptorsPresent : List String =
        case locOpt of
          Just loc =>
            filter (\r => isPrefixOf loc r && elem (stemOf r) descriptorStems
                       && isSuffixOf ".a2ml" (toLower r)) rels
          Nothing => []
  let hasContractiles : Bool =
        any (\r => isSuffixOf ".k9.ncl" (toLower r) || elem "contractiles" (dirsOf r)) rels
  let hasBots : Bool = not (null (underDir ".machine_readable/bot_directives/" rels))
  let hasAnchors : Bool =
        not (null (underDir ".machine_readable/anchors/" rels))
        || not (null (underDir ".machine_readable/anchor/" rels))
        || any (\r => isSuffixOf ".anchor.yaml" (toLower r) || isSuffixOf ".anchor.yml" (toLower r)) rels
  let claudeRoot : List String =
        filter (\r => toLower r == "claude.md") rels
  let applicable : Bool = case locOpt of
                         Just _  => True
                         Nothing => hasContractiles || hasBots || hasAnchors
                                    || not (null claudeRoot)

  if not applicable
    then do
      emitStatus githubOutput "not_applicable"
      putStrLn "::notice::semantic-audit-check: no audited artefacts (descriptiles, K9 contracts, bot_directives, anchors, root CLAUDE.md) — not applicable, nothing was audited."
      exitSuccess
    else pure ()

  putStrLn ("semantic-audit-check: artefacts — descriptors: " ++ show (length descriptorsPresent)
            ++ ", K9/contractiles: " ++ show (length (filter (\r => isSuffixOf ".k9.ncl" (toLower r)) rels))
            ++ ", CLAUDE.md: " ++ if null claudeRoot then "absent" else "present")

  -- ----------------------------------------------------- S2..S6 checks
  d1 <- s2CoreSet d0 locOpt descriptorsPresent
  d2 <- surfaceNotes d1 locOpt descriptorsPresent
  d4 <- s3Policy d2 rels descriptorsPresent
  d5 <- s4K9 d4 rels

  -- legacy layout notice
  let legacyDeclarations : List String = filter (\r => isSuffixOf ".a2ml" (toLower r) && any (\seg => seg == "contractiles") (dirsOf r)) rels
  let d8 : Diag = if null legacyDeclarations
             then d5
             else Diag.warning d5 (show (length legacyDeclarations)
                  ++ " legacy .a2ml declaration(s) under contractiles/ — a2ml is retired (standards #837); migrate to K9 contracts.")

  -- deed notice
  let deeds : List String = filter (\r => isSuffixOf ".deed" (toLower r)) rels
  let d9 : Diag = if null deeds
             then d8
             else Diag.notice d8 (show (length deeds) ++ " .deed declaration(s) present — grammar validation is the deed-lint lane, not this gate.")

  d10 <- s5ClaudeMd d9 claudeRoot
  let d12 : Diag = s6Presence d10 rels

  -- -------------------------------------------------------------- verdict
  printReport "semantic-audit-check" d12
  emitStatus githubOutput (Diag.status d12)
  if Diag.isFail d12
    then exitWith (ExitFailure 1)
    else exitSuccess

