#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check.sh — the Creusot gate for Rust, parallel to the SPARK gate for Ada.
#
# Creusot (https://github.com/creusot-rs/creusot) is a deductive verifier for
# Rust: a crate depends on `creusot-std` (named `creusot-contracts` before
# v0.9.0), annotates functions with `#[requires(..)]` / `#[ensures(..)]`, and
# `cargo creusot` discharges the obligations through Why3 and SMT
# solvers. "Verified with Creusot" is therefore a claim with an oracle, and
# this gate makes the claim and the oracle agree. Three phases:
#
#   CREUSOT_GATE_PHASE=detect
#       Prints `key=value` facts: obligations (true when any crate carries a
#       Creusot dependency or contract attribute), claims (true when prose or a
#       source header asserts Creusot verification), crates (the manifest
#       directories carrying obligations, newline-separated in a file),
#       creusot_version (from the dependency spec, else "").
#
#   CREUSOT_GATE_PHASE=theatre   (the anti-theatre tier, mirrors
#                                 standards' SPARK Theatre Gate T1/T2)
#       T1  a claim with no obligations behind it: hard failure, always.
#       T2  a Creusot dependency with ZERO contract attributes anywhere: a
#           hollow dependency proves nothing. Warning by default; a hard
#           failure when ENFORCE_HOLLOW=true.
#       T3  every `#[trusted]` is printed. `trusted` is an axiom the prover
#           takes on faith; the gate never fails on it, but it never lets one
#           pass unlisted either (the residue list of the proof).
#
#   CREUSOT_GATE_PHASE=prove
#       Requires `cargo creusot` on PATH (the workflow installs it, pinned).
#       FIRST proves a planted known-failing contract and REQUIRES a non-zero
#       exit; then a planted known-good one and requires zero. A prover that
#       cannot say no is not a prover, and the verdict over the caller's
#       crate would be VOID — so the gate refuses (exit 2) rather than report
#       green. Only then does it run `cargo creusot` in every crate
#       directory that carries obligations, failing on any non-zero exit.
#
# Exit codes: 0 silent, 1 defect found, 2 NO CHECK WAS PERFORMED (tool
# missing, planted control misbehaved, unreadable tree). 2 is never a pass.
#
# Env: WORKING_DIRECTORY (default "."), ENFORCE_HOLLOW (default false),
#      PROVE_ARGS (appended to `cargo creusot`), CREUSOT_FACTS (path
#      the detect phase writes its crate list to; default $RUNNER_TEMP or
#      /tmp).
set -uo pipefail

phase="${CREUSOT_GATE_PHASE:?CREUSOT_GATE_PHASE is required: detect|theatre|prove}"
dir="${WORKING_DIRECTORY:-.}"
enforce_hollow="${ENFORCE_HOLLOW:-false}"
prove_args="${PROVE_ARGS:-}"
facts_dir="${CREUSOT_FACTS:-${RUNNER_TEMP:-/tmp}/creusot-facts}"
mkdir -p "$facts_dir"

cd "$dir" || { echo "::error::creusot-check[$phase]: cannot enter $dir — NO CHECK WAS PERFORMED." >&2; exit 2; }

# Tracked files only: an untracked checkout of this suite (.cicd-suite/) or a
# target/ tree must never count as the caller's sources.
list_files() { # <ere on path>
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files -z | tr '\0' '\n' | grep -E "$1" || true
  else
    find . -type f -not -path '*/.git/*' -not -path '*/target/*' -not -path '*/.cicd-suite/*' \
      | sed 's#^\./##' | grep -E "$1" || true
  fi
}

# ---------------------------------------------------------------- facts ----
manifests="$(list_files '(^|/)Cargo\.toml$')"
obligation_manifests=""
creusot_version=""
while IFS= read -r m; do
  [ -n "$m" ] || continue
  # A dependency line for the proof library, under any dependency table.
  if grep -qE '^[[:space:]]*(creusot-std|creusot-contracts)[[:space:]]*=' "$m" \
     || grep -qE '^[[:space:]]*\[(workspace\.)?dependencies\.(creusot-std|creusot-contracts)\]' "$m"; then
    obligation_manifests="${obligation_manifests}${m}"$'\n'
    if [ -z "$creusot_version" ]; then
      creusot_version="$(sed -nE 's/^[[:space:]]*(creusot-std|creusot-contracts)[[:space:]]*=[[:space:]]*(\{[^}]*version[[:space:]]*=[[:space:]]*)?"([^"]+)".*$/\3/p' "$m" | head -n 1 || true)"
    fi
  fi
done <<< "$manifests"

contract_re='#\[(requires|ensures|invariant|variant|logic|law|open|predicate|terminates|pure|trusted)(\(|\])|proof_assert!|#\[creusot::'
rust_sources="$(list_files '\.rs$')"
contract_files=""
contract_count=0
trusted_count=0
if [ -n "$rust_sources" ]; then
  contract_files="$(printf '%s\n' "$rust_sources" | xargs -r grep -lE "$contract_re" 2>/dev/null || true)"
  contract_count="$({ printf '%s\n' "$rust_sources" | xargs -r grep -cE '#\[(requires|ensures)\(' 2>/dev/null || true; } | awk -F: '{s+=$NF} END {print s+0}')"
  trusted_count="$({ printf '%s\n' "$rust_sources" | xargs -r grep -cE '#\[trusted\]' 2>/dev/null || true; } | awk -F: '{s+=$NF} END {print s+0}')"
fi

obligations=false
if [ -n "$obligation_manifests" ] || [ -n "$contract_files" ]; then obligations=true; fi

# A claim is a sentence in prose or a source HEADER that asserts the proof
# exists. Scoped to README*/docs/** and to the leading comment block of a
# Rust file, like the SPARK gate's header rule: a design note deep in a body,
# or a proposal that mentions Creusot as a plan, is not a claim about this
# tree. The negative lookbehind words ("planned", "proposal", "would", "not
# yet") are the honest-roadmap vocabulary and are excluded by hand below.
claim_re='(verified (with|by|using) creusot|creusot[- ]verified|proved (with|by|using) creusot|creusot proofs? (pass|discharged)|creusot: (all|every) (goal|obligation)s? (proved|discharged))'
plan_re='(planned|proposal|proposed|roadmap|not yet|would|future|todo|intend)'
claim_sites=""
prose="$(list_files '(^|/)(README[^/]*|[^/]*\.(adoc|md))$' | grep -vE '^(\.cicd-suite|target)/' || true)"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    printf '%s' "$hit" | grep -qiE "$plan_re" && continue
    claim_sites="${claim_sites}${f}:${hit%%:*}"$'\n'
  done < <(grep -niE "$claim_re" "$f" 2>/dev/null || true)
done <<< "$prose"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  header="$(awk '/^[[:space:]]*(\/\/|\/\*|\*)/ || /^[[:space:]]*$/ { print; next } { exit }' "$f")"
  if printf '%s\n' "$header" | grep -qiE "$claim_re" \
     && ! printf '%s\n' "$header" | grep -qiE "$plan_re"; then
    claim_sites="${claim_sites}${f}:1"$'\n'
  fi
done <<< "$rust_sources"
claims=false
[ -n "$claim_sites" ] && claims=true

crate_dirs="$(printf '%s' "$obligation_manifests" | sed -E 's#(^|/)Cargo\.toml$##; s#^$#.#' | sort -u)"
printf '%s\n' "$crate_dirs" | sed '/^$/d' > "$facts_dir/crates"
printf '%s' "$claim_sites" > "$facts_dir/claims"

case "$phase" in
  detect)
    printf 'obligations=%s\n' "$obligations"
    printf 'claims=%s\n' "$claims"
    printf 'creusot_version=%s\n' "$creusot_version"
    printf 'contract_count=%s\n' "$contract_count"
    printf 'trusted_count=%s\n' "$trusted_count"
    printf 'crates_file=%s\n' "$facts_dir/crates"
    exit 0
    ;;

  theatre)
    fail=0
    if [ "$claims" = true ] && [ "$obligations" = false ]; then
      while IFS= read -r site; do
        [ -n "$site" ] || continue
        echo "::error file=${site%%:*},line=${site##*:}::T1 Creusot theatre: this says the code is verified with Creusot, but no crate depends on creusot-std and no #[requires]/#[ensures] exists. Add the contracts and the dependency, or remove the claim (standards#692: Rust + Creusot, without proof theatre)."
      done <<< "$claim_sites"
      fail=1
    fi
    if [ "$obligations" = true ] && [ "$contract_count" -eq 0 ]; then
      msg="T2 hollow Creusot dependency: creusot-std/creusot-contracts is a dependency but no #[requires]/#[ensures] appears in any tracked .rs file, so 'cargo creusot' would discharge nothing. Write a contract on at least one function, or drop the dependency."
      if [ "$enforce_hollow" = true ]; then
        echo "::error::$msg"; fail=1
      else
        echo "::warning::$msg (escalates to a failure with enforce_hollow: true)"
      fi
    fi
    if [ "$trusted_count" -gt 0 ]; then
      echo "::notice::T3 residue: $trusted_count #[trusted] item(s) are taken as axioms by the prover. They are listed below; a proof is only as strong as its trusted set."
      printf '%s\n' "$rust_sources" | xargs -r grep -nE '#\[trusted\]' 2>/dev/null | sed 's/^/  trusted: /' || true
    fi
    if [ "$obligations" = false ] && [ "$claims" = false ]; then
      echo "::notice::creusot-check: no Creusot obligations and no verification claims in this tree. Nothing was proved and nothing claims to be — this gate is silent, not green-as-assurance."
    fi
    [ "$fail" -eq 0 ] || { echo "::error::creusot-check[theatre]: FAILED — see annotations."; exit 1; }
    echo "creusot-check[theatre]: no theatre found (obligations=$obligations claims=$claims contracts=$contract_count trusted=$trusted_count)."
    exit 0
    ;;

  prove)
    if [ "$obligations" = false ]; then
      echo "::error::creusot-check[prove]: no Creusot obligations in this tree — NO PROOF WAS PERFORMED. The prove job must only run when detect reported obligations=true." >&2
      exit 2
    fi
    command -v cargo >/dev/null 2>&1 && cargo creusot --help >/dev/null 2>&1 || {
      echo "::error::creusot-check[prove]: 'cargo creusot' is not available — NO PROOF WAS PERFORMED. The workflow installs Creusot (pinned) before this step." >&2
      exit 2
    }

    # ---- planted controls: the prover must be able to say NO -------------
    ctl="$(mktemp -d)"
    # Create a named control crate under $ctl from the supplied Rust source.
    # If initialisation fails or why3find.json is missing or empty, remove $ctl
    # and exit 2 (no proof performed).
    plant() { # <name> <body>
      mkdir -p "$ctl/$1/src"
      cat > "$ctl/$1/Cargo.toml" <<TOML
[package]
name = "$1"
version = "0.0.0"
edition = "2021"
[dependencies]
creusot-std = "${creusot_version:-*}"
TOML
      printf '%s\n' "$2" > "$ctl/$1/src/lib.rs"
      # v0.14 init copies the installed Why3find configuration into this
      # private control crate. Never initialise or rewrite the caller's tree.
      if ! (cd "$ctl/$1" && cargo creusot init "$1") || [ ! -s "$ctl/$1/why3find.json" ]; then
        echo "::error::creusot-check[prove]: control initialisation did not supply why3find.json. NO PROOF WAS PERFORMED." >&2
        rm -rf "$ctl"; exit 2
      fi
    }
    plant creusot-control-failing 'use creusot_std::prelude::*;
#[ensures(result == 0u32)]
pub fn planted_must_fail() -> u32 { 1 }'
    plant creusot-control-passing 'use creusot_std::prelude::*;
#[ensures(result == 2u32)]
pub fn planted_must_pass() -> u32 { 2 }'
    echo "::group::planted control: a false postcondition must NOT prove"
    # shellcheck disable=SC2086
    if (cd "$ctl/creusot-control-failing" && cargo creusot $prove_args); then
      echo "::endgroup::"
      echo "::error::creusot-check[prove]: the planted FALSE contract was reported proved (exit 0). This prover cannot fail, so any verdict it gives over the caller's crate is VOID. NO PROOF WAS PERFORMED." >&2
      rm -rf "$ctl"; exit 2
    fi
    echo "::endgroup::"
    echo "planted control: false contract refused — the oracle can say no."
    echo "::group::planted control: a true postcondition must prove"
    # shellcheck disable=SC2086
    if ! (cd "$ctl/creusot-control-passing" && cargo creusot $prove_args); then
      echo "::endgroup::"
      echo "::error::creusot-check[prove]: the planted TRUE contract did not prove. The toolchain is broken (solver or prelude), so a red on the caller's crate would be misattributed. NO PROOF WAS PERFORMED." >&2
      rm -rf "$ctl"; exit 2
    fi
    echo "::endgroup::"
    rm -rf "$ctl"
    echo "planted control: true contract proved — the oracle can say yes."

    # ---- the caller's crates ---------------------------------------------
    fail=0
    while IFS= read -r crate; do
      [ -n "$crate" ] || continue
      echo "::group::cargo creusot — $crate"
      # shellcheck disable=SC2086
      if (cd "$crate" && cargo creusot $prove_args); then
        echo "::endgroup::"
        echo "ok: $crate — every obligation discharged"
      else
        rc=$?
        echo "::endgroup::"
        echo "::error file=$crate/Cargo.toml::creusot-check[prove]: 'cargo creusot' exited $rc in $crate — at least one obligation is unproved. Fix the contract or the code; never mark it #[trusted] to get green."
        fail=1
      fi
    done < "$facts_dir/crates"
    [ "$fail" -eq 0 ] || exit 1
    echo "creusot-check[prove]: all Creusot obligations discharged (trusted axioms: $trusted_count)."
    exit 0
    ;;
  *)
    echo "::error::creusot-check: unknown phase '$phase' (detect|theatre|prove)" >&2
    exit 2
    ;;
esac
