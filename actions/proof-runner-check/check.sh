#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# proof-runner-check — run the proof projects actually in the tree.
#
# Same pass-on-absence defect as the old custom-tools-check: the inline
# version had its only tool invocation commented out
# (`# idris2 --typecheck *.ipkg || exit 1`) and printed "All detected
# proofs executed successfully." whether or not anything — or any
# proof tool — existed.
#
# Contract:
#   0  no proof project in the tree (not applicable, said so with
#      ::notice:: — never "executed successfully"), OR every detected
#      project's tool was on PATH, ran, and exited 0
#   1  a proof tool ran and failed (unproved / ill-typed project)
#   2  a proof project is present but its tool is not on PATH —
#      NO CHECK WAS PERFORMED (status=not_run). Never a pass.
#
# Supported projects: Idris2 (*.ipkg -> idris2 --typecheck) and Lean
# (lakefile.lean / lakefile.toml -> lake build). Callers must install
# the toolchain first; the estate audit no longer runs this gate (the
# language gates install their own provers).

set -uo pipefail

dir="${PROOF_RUNNER_WORKDIR:-.}"
cd "$dir" || { echo "::error::proof-runner-check: cannot enter $dir — NO CHECK WAS PERFORMED." >&2; exit 2; }

emit_status() {
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "status=$1" >> "$GITHUB_OUTPUT"
  echo "proof-runner-check status=$1"
}

declare -a projects=() tools=()
while IFS= read -r f; do projects+=("$f"); tools+=(idris2); done \
  < <(find . -path ./.git -prune -o -name '*.ipkg' -print 2>/dev/null | sort)
for lf in lakefile.lean lakefile.toml; do
  [ -f "$lf" ] && { projects+=("$lf"); tools+=(lake); }
done

if [ "${#projects[@]}" -eq 0 ]; then
  emit_status not_applicable
  echo "::notice::proof-runner-check: no proof project (*.ipkg, lakefile.lean/toml) found — not applicable, no proofs were executed."
  exit 0
fi

missing=()
for t in "${tools[@]}"; do
  command -v "$t" >/dev/null 2>&1 || missing+=("$t (for its proof project)")
done
if [ "${#missing[@]}" -gt 0 ]; then
  emit_status not_run
  echo "::error::proof-runner-check: proof project(s) present (${projects[*]}) but not on PATH: ${missing[*]} — NO CHECK WAS PERFORMED (status=not_run). Install the toolchain before this step, or do not call this gate." >&2
  exit 2
fi

fail=0
for i in "${!projects[@]}"; do
  case "${tools[$i]}" in
    idris2)
      echo "Running: idris2 --typecheck ${projects[$i]}"
      idris2 --typecheck "${projects[$i]}" \
        || { rc=$?; echo "::error::proof-runner-check: idris2 exited $rc on ${projects[$i]}."; fail=1; } ;;
    lake)
      echo "Running: lake build"
      lake build \
        || { rc=$?; echo "::error::proof-runner-check: 'lake build' exited $rc."; fail=1; } ;;
  esac
done

if [ "$fail" -eq 1 ]; then
  emit_status failed
  exit 1
fi

emit_status passed
echo "Proof runner passed (${#projects[@]} proof project(s) actually executed and exited 0)."
