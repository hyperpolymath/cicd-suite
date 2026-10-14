#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check.sh — the Ada/SPARK proof gate: GNATprove actually runs, and its
# verdict is the gate's verdict.
#
# The claim side ("this unit is formally verified") is policed by
# hyperpolymath/standards' SPARK Theatre Gate, which the reusable workflow
# spark-gate.yml calls first. This script is the ORACLE side, in two phases:
#
#   SPARK_GATE_PHASE=detect
#       Prints `key=value` facts: spark_units (tracked .ads/.adb with an
#       active SPARK_Mode On, comment lines ignored), gpr_count, project (the
#       .gpr GNATprove will be given). The project is the GPR input when set;
#       otherwise the single tracked .gpr. With SPARK units present and zero
#       or several .gpr files and no input, detect FAILS (exit 1): the gate
#       never guesses which project is the proof unit.
#
#   SPARK_GATE_PHASE=prove
#       Requires `gnatprove` on PATH (the workflow installs it via Alire,
#       pinned). FIRST proves two planted units: a false postcondition MUST
#       make gnatprove exit non-zero under --checks-as-errors=on, and a true
#       one MUST exit zero. A prover that cannot say no voids every verdict
#       it gives, so the gate refuses (exit 2) instead of reporting green.
#       Then: gnatprove -P <project> --mode=all --level=<LEVEL>
#             --checks-as-errors=on --warnings=error --report=all
#             --timeout=<TIMEOUT> -j0 <EXTRA_ARGS>
#       Non-zero exit fails. Belt and braces: any `medium:`/`high:`/`low:`
#       unproved-check message in the log fails even on a zero exit, and the
#       summary (gnatprove.out) is printed so the proof's shape is on record.
#
# Exit codes: 0 silent, 1 defect, 2 NO CHECK WAS PERFORMED. 2 is never a pass.
#
# Env: WORKING_DIRECTORY (default "."), GPR (optional), LEVEL (default 2),
#      TIMEOUT (default 60, seconds per VC), EXTRA_ARGS.
set -uo pipefail

phase="${SPARK_GATE_PHASE:?SPARK_GATE_PHASE is required: detect|prove}"
dir="${WORKING_DIRECTORY:-.}"
gpr_input="${GPR:-}"
level="${LEVEL:-2}"
timeout_s="${TIMEOUT:-60}"
extra_args="${EXTRA_ARGS:-}"

cd "$dir" || { echo "::error::spark-check[$phase]: cannot enter $dir — NO CHECK WAS PERFORMED." >&2; exit 2; }

list_files() { # <ere on path>
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files -z | tr '\0' '\n' | grep -E "$1" || true
  else
    find . -type f -not -path '*/.git/*' -not -path '*/obj/*' -not -path '*/.cicd-suite/*' \
      | sed 's#^\./##' | grep -E "$1" || true
  fi
}

sparkon_re='pragma[[:space:]]+SPARK_Mode[[:space:]]*\([[:space:]]*On[[:space:]]*\)|with[[:space:]]+SPARK_Mode[[:space:]]*=>[[:space:]]*On'
units=0
unit_list=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if grep -vE '^[[:space:]]*--' "$f" | grep -qE "$sparkon_re"; then
    units=$((units+1)); unit_list="${unit_list}${f}"$'\n'
  fi
done <<< "$(list_files '\.(ads|adb)$')"

gprs="$(list_files '\.gpr$')"
gpr_count=0
[ -n "$gprs" ] && gpr_count="$(printf '%s\n' "$gprs" | sed '/^$/d' | wc -l | tr -d ' ')"

project=""
if [ -n "$gpr_input" ]; then
  project="$gpr_input"
elif [ "$gpr_count" -eq 1 ]; then
  project="$(printf '%s\n' "$gprs" | sed '/^$/d')"
fi

case "$phase" in
  detect)
    printf 'spark_units=%s\n' "$units"
    printf 'gpr_count=%s\n' "$gpr_count"
    printf 'project=%s\n' "$project"
    if [ "$units" -gt 0 ]; then
      if [ -n "$gpr_input" ] && [ ! -f "$gpr_input" ]; then
        echo "::error::spark-check[detect]: gpr input '$gpr_input' does not exist. Name the project file that owns the SPARK units." >&2
        exit 1
      fi
      if [ -z "$project" ]; then
        echo "::error::spark-check[detect]: $units SPARK_Mode-On unit(s) but $gpr_count .gpr file(s) and no 'gpr' input — the gate will not guess which project is the proof unit. Pass gpr: <path>." >&2
        printf '%s' "$unit_list" | sed 's/^/  unit: /' >&2
        exit 1
      fi
    fi
    exit 0
    ;;

  prove)
    if [ "$units" -eq 0 ]; then
      echo "::error::spark-check[prove]: no SPARK_Mode-On unit in this tree — NO PROOF WAS PERFORMED. The prove job must only run when detect reported spark_units > 0." >&2
      exit 2
    fi
    [ -n "$project" ] && [ -f "$project" ] || {
      echo "::error::spark-check[prove]: no project to prove (project='$project') — NO PROOF WAS PERFORMED." >&2; exit 2; }
    command -v gnatprove >/dev/null 2>&1 || {
      echo "::error::spark-check[prove]: gnatprove is not on PATH — NO PROOF WAS PERFORMED. The workflow installs it (Alire, pinned) before this step." >&2; exit 2; }

    common=(--mode=all "--level=$level" --checks-as-errors=on --warnings=error --report=all "--timeout=$timeout_s" -j0)

    # ---- planted controls --------------------------------------------------
    ctl="$(mktemp -d)"
    plant() { # <dir> <pkg> <post-expr> <body-expr>
      mkdir -p "$ctl/$1/src"
      printf 'project %s is\n   for Source_Dirs use ("src");\n   for Object_Dir use "obj";\nend %s;\n' "$2" "$2" > "$ctl/$1/$2.gpr"
      printf 'package %s with SPARK_Mode => On is\n   function F (X : Integer) return Integer with Post => %s;\nend %s;\n' "$2" "$3" "$2" > "$ctl/$1/src/$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]').ads"
      printf 'package body %s with SPARK_Mode => On is\n   function F (X : Integer) return Integer is (%s);\nend %s;\n' "$2" "$4" "$2" > "$ctl/$1/src/$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]').adb"
    }
    plant failing Planted_Must_Fail "F'Result = 0" "1"
    plant passing Planted_Must_Pass "F'Result = X" "X"
    echo "::group::planted control: a false postcondition must NOT prove"
    if (cd "$ctl/failing" && gnatprove -P Planted_Must_Fail.gpr "${common[@]}"); then
      echo "::endgroup::"
      echo "::error::spark-check[prove]: gnatprove reported the planted FALSE postcondition proved (exit 0 under --checks-as-errors=on). This prover cannot fail; every verdict it gives is VOID. NO PROOF WAS PERFORMED." >&2
      rm -rf "$ctl"; exit 2
    fi
    echo "::endgroup::"
    echo "planted control: false postcondition refused — the oracle can say no."
    echo "::group::planted control: a true postcondition must prove"
    if ! (cd "$ctl/passing" && gnatprove -P Planted_Must_Pass.gpr "${common[@]}"); then
      echo "::endgroup::"
      echo "::error::spark-check[prove]: gnatprove could not prove the planted TRUE postcondition. The toolchain (provers) is broken, so a red on the caller's project would be misattributed. NO PROOF WAS PERFORMED." >&2
      rm -rf "$ctl"; exit 2
    fi
    echo "::endgroup::"
    rm -rf "$ctl"
    echo "planted control: true postcondition proved — the oracle can say yes."

    # ---- the caller's project --------------------------------------------
    log="$(mktemp)"
    marker="$(mktemp)"
    echo "::group::gnatprove -P $project ${common[*]} $extra_args"
    # shellcheck disable=SC2086 # extra_args is deliberately word-split
    rc=0
    gnatprove -P "$project" "${common[@]}" $extra_args 2>&1 | tee "$log" || rc=$?
    echo "::endgroup::"

    fail=0
    if [ "$rc" -ne 0 ]; then
      echo "::error file=$project::spark-check[prove]: gnatprove exited $rc — unproved checks or flow errors (listed above). Fix the code or the contract; never set SPARK_Mode Off to get green."
      fail=1
    fi
    # Unproved check messages, should any survive a zero exit.
    if grep -qE '^[^:]+:[0-9]+:[0-9]+: (medium|high|low): ' "$log"; then
      echo "::error file=$project::spark-check[prove]: unproved check message(s) in the GNATprove log:"
      grep -E '^[^:]+:[0-9]+:[0-9]+: (medium|high|low): ' "$log" | sed 's/^/  /'
      fail=1
    fi
    summary="$(find . -name gnatprove.out -newer "$marker" -not -path '*/.cicd-suite/*' 2>/dev/null | head -n 1 || true)"
    if [ -n "$summary" ]; then
      echo "::group::GNATprove summary ($summary)"
      cat "$summary"
      echo "::endgroup::"
    else
      echo "::warning::spark-check[prove]: no gnatprove.out summary was written — the run's shape is not on record."
    fi
    rm -f "$log" "$marker"
    [ "$fail" -eq 0 ] || exit 1
    echo "spark-check[prove]: $units SPARK unit(s) in $project — every check proved at level $level."
    exit 0
    ;;
  *)
    echo "::error::spark-check: unknown phase '$phase' (detect|prove)" >&2
    exit 2
    ;;
esac
