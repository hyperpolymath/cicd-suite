#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check.sh — the miniKanren gate: relational code is RUN, not admired.
#
# A relation that is never executed is a claim, not a check, and a
# relational program that reaches for committed choice (conda/condu),
# projection or copy-term has quietly stopped being relational — it no
# longer runs backwards, which is the property the estate wants from
# miniKanren (cicd-squabbler's Reasoner design; the archived
# state-kanren.scm). Four tiers, one invocation:
#
#   DETECT   tracked relational sources: Scheme-family files (.scm .ss .sls
#            .sld .rkt) that both build goals (run/run*/fresh/conde/==) and
#            load or define a miniKanren; Rust crates depending on a kanren
#            crate (canrun, ukanren, kanren, mukanren, minikanren).
#   T1 claim a README/docs sentence saying this tree USES miniKanren or a
#            relational reasoner, with zero relational sources behind it.
#            Warning by default (proposals and roadmaps mention it
#            legitimately — the plan vocabulary is excluded); a failure
#            with ENFORCE_CLAIMS=true.
#   T2 tests every relational source set must have at least one relational
#            test file (under test/ tests/ spec/, named *-test.* / *.test.*
#            / *_test.*, or containing assert/test-* forms). Failure by
#            default (REQUIRE_TESTS=true); a warning when false.
#   RUN      every relational test file is executed with the interpreter its
#            dialect names: .rkt → racket; (use-modules …) → guile;
#            (import (…))/(library …) → Chez `scheme --script`; otherwise
#            guile. A missing interpreter is exit 2 — NO CHECK WAS
#            PERFORMED — never a pass. Rust kanren crates run
#            `cargo test --locked -p <crate>`.
#   T3 purity occurrences of conda, condu, project, onceo, ifa, ifu,
#            copy-term in relational sources are listed as warnings; failures
#            with ENFORCE_PURITY=true.
#
# Exit codes: 0 silent, 1 defect, 2 NO CHECK WAS PERFORMED.
#
# Env: WORKING_DIRECTORY (default "."), REQUIRE_TESTS (default true),
#      ENFORCE_PURITY (default false), ENFORCE_CLAIMS (default false).
set -uo pipefail

dir="${WORKING_DIRECTORY:-.}"
require_tests="${REQUIRE_TESTS:-true}"
enforce_purity="${ENFORCE_PURITY:-false}"
enforce_claims="${ENFORCE_CLAIMS:-false}"

cd "$dir" || { echo "::error::kanren-check: cannot enter $dir — NO CHECK WAS PERFORMED." >&2; exit 2; }

list_files() { # <ere on path>
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files -z | tr '\0' '\n' | grep -E "$1" || true
  else
    find . -type f -not -path '*/.git/*' -not -path '*/target/*' -not -path '*/.cicd-suite/*' \
      | sed 's#^\./##' | grep -E "$1" || true
  fi
}

goal_re='\((run\*?[[:space:]]|run[[:space:]]+[0-9]|fresh[[:space:]]*\(|conde[[:space:]]|==[[:space:]])'
mk_re='(minikanren|mini-kanren|microkanren|mk\.scm|\(define-syntax[[:space:]]+(run\*?|fresh|conde)|\(define[[:space:]]+\(==[[:space:]])'
test_path_re='(^|/)(test|tests|spec)/|[-_.](test|tests|spec)\.(scm|ss|sls|sld|rkt)$'
test_form_re='\((assert|test-assert|test-equal|test-eq|test-begin|check-equal\?|check-expect|check-true|rackunit|srfi[[:space:]]+64)'
impure_re='\((conda|condu|project|onceo|ifa|ifu|copy-term)[[:space:]]'
claim_re='(uses? (a )?(minikanren|mini-kanren)|relational (reasoner|rule base|rules engine|programming)|minikanren(-| )based|implemented (in|with) minikanren)'
plan_re='(planned|proposal|proposed|roadmap|not yet|would|future|todo|intend|optional|adopt|whether)'
kanren_crates='(canrun|ukanren|kanren|mukanren|minikanren)'

# ------------------------------------------------------------- DETECT ------
scheme_files="$(list_files '\.(scm|ss|sls|sld|rkt)$')"
engine_re='\(define-syntax[[:space:]]+(run\*?|fresh|conde)[[:space:]]'
rel_files=""
engine_files=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # The file that DEFINES run/fresh/conde is the engine, not a relation over it.
  if grep -qE "$engine_re" "$f"; then
    engine_files="${engine_files}${f}"$'\n'
  elif grep -qE "$goal_re" "$f" && grep -qiE "$mk_re" "$f"; then
    rel_files="${rel_files}${f}"$'\n'
  fi
done <<< "$scheme_files"

rel_tests=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if printf '%s' "$f" | grep -qE "$test_path_re" || grep -qE "$test_form_re" "$f"; then
    rel_tests="${rel_tests}${f}"$'\n'
  fi
done <<< "$rel_files"

rust_crates=""
while IFS= read -r m; do
  [ -n "$m" ] || continue
  if grep -qE "^[[:space:]]*${kanren_crates}[[:space:]]*=" "$m" \
     || grep -qE "^[[:space:]]*\[(workspace\.)?dependencies\.${kanren_crates}\]" "$m"; then
    name="$(sed -nE 's/^[[:space:]]*name[[:space:]]*=[[:space:]]*"([^"]+)".*$/\1/p' "$m" | head -n 1 || true)"
    [ -n "$name" ] && rust_crates="${rust_crates}${name}"$'\n'
  fi
done <<< "$(list_files '(^|/)Cargo\.toml$')"

n_rel="$(printf '%s' "$rel_files" | grep -c . || true)"
n_tests="$(printf '%s' "$rel_tests" | grep -c . || true)"
n_rust="$(printf '%s' "$rust_crates" | grep -c . || true)"
echo "kanren-check: relational Scheme files=$n_rel (tests=$n_tests), Rust kanren crates=$n_rust"
printf '%s' "$rel_files" | sed '/^$/d; s/^/  relational: /'
printf '%s' "$engine_files" | sed '/^$/d; s/^/  engine: /'
printf '%s' "$rust_crates" | sed '/^$/d; s/^/  rust crate: /'

fail=0
warn() { echo "::warning::kanren-check: $*"; }
err()  { echo "::error::kanren-check: $*"; fail=1; }

# ------------------------------------------------------------- T1 claim ----
if [ "$n_rel" -eq 0 ] && [ "$n_rust" -eq 0 ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      printf '%s' "$hit" | grep -qiE "$plan_re" && continue
      msg="T1 claim without relations: $f:${hit%%:*} says this tree uses miniKanren / a relational reasoner, but no relational source exists. Write the relations (and their tests), or word it as a plan."
      if [ "$enforce_claims" = true ]; then err "$msg"; else warn "$msg"; fi
    done < <(grep -niE "$claim_re" "$f" 2>/dev/null || true)
  done <<< "$(list_files '(^|/)(README[^/]*|[^/]*\.(adoc|md))$' | grep -vE '^(\.cicd-suite|target)/' || true)"
  if [ "$fail" -eq 0 ]; then
    echo "::notice::kanren-check: no relational sources in this tree. Nothing was run — this gate is silent, not green-as-assurance."
    exit 0
  fi
  exit 1
fi

# ------------------------------------------------------------- T2 tests ----
if [ "$n_rel" -gt 0 ] && [ "$n_tests" -eq 0 ]; then
  msg="T2 relations without a goal-level test: $n_rel relational file(s) and no relational test file (tests/ or *-test.scm, or a file with assert/test-* forms). A relation never run is a claim, not a check."
  if [ "$require_tests" = true ]; then err "$msg"; else warn "$msg (REQUIRE_TESTS=false)"; fi
fi

# ------------------------------------------------------------- RUN ---------
interpreter_for() { # <file> → prints command words or nothing
  case "$1" in
    *.rkt) command -v racket >/dev/null 2>&1 && echo "racket" ;;
    *)
      if grep -qE '\(use-modules' "$1"; then
        command -v guile >/dev/null 2>&1 && echo "guile --no-auto-compile -s"
      elif grep -qE '\((import|library)[[:space:]]*\(' "$1"; then
        command -v scheme >/dev/null 2>&1 && echo "scheme --script"
      else
        command -v guile >/dev/null 2>&1 && echo "guile --no-auto-compile -s"
      fi
      ;;
  esac
}
ran=0
while IFS= read -r t; do
  [ -n "$t" ] || continue
  cmd="$(interpreter_for "$t" || true)"  # a missing interpreter is a RESULT, not a -e kill
  if [ -z "$cmd" ]; then
    echo "::error file=$t::kanren-check: no interpreter on PATH for $t (racket for .rkt; guile for (use-modules …); Chez 'scheme' for R6RS) — NO CHECK WAS PERFORMED." >&2
    exit 2
  fi
  echo "::group::$cmd $t"
  # Run from the file's directory so relative (load "../mk.scm") resolves.
  # shellcheck disable=SC2086 # cmd is deliberately word-split
  if (cd "$(dirname "$t")" && $cmd "$(basename "$t")"); then
    echo "::endgroup::"; echo "ok: $t"; ran=$((ran+1))
  else
    rc=$?
    echo "::endgroup::"
    err "relational test $t failed (exit $rc). The relation does not hold — fix the relation or the expectation; never delete the test."
  fi
done <<< "$rel_tests"

if [ "$n_rust" -gt 0 ]; then
  command -v cargo >/dev/null 2>&1 || { echo "::error::kanren-check: Rust kanren crate(s) present but cargo is not on PATH — NO CHECK WAS PERFORMED." >&2; exit 2; }
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    echo "::group::cargo test --locked -p $c"
    if cargo test --locked -p "$c"; then
      echo "::endgroup::"; echo "ok: crate $c"; ran=$((ran+1))
    else
      rc=$?; echo "::endgroup::"
      err "cargo test --locked -p $c failed (exit $rc)."
    fi
  done <<< "$rust_crates"
fi

# ------------------------------------------------------------- T3 purity ---
while IFS= read -r f; do
  [ -n "$f" ] || continue
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    op="$(printf '%s' "$hit" | grep -oE "$impure_re" | head -n 1 | tr -d '( ' || true)"
    msg="T3 impure operator '$op' at $f:${hit%%:*} — committed choice / projection / copy-term breaks the relation's reversibility. Prefer conde, ==, =/= and fresh."
    if [ "$enforce_purity" = true ]; then err "$msg"; else warn "$msg (escalates with enforce_purity: true)"; fi
  done < <(grep -nE "$impure_re" "$f" 2>/dev/null || true)
done <<< "$rel_files"

[ "$fail" -eq 0 ] || { echo "::error::kanren-check: FAILED — see annotations."; exit 1; }
echo "kanren-check: $ran relational test run(s) passed over $n_rel relational file(s) and $n_rust Rust crate(s)."
exit 0
