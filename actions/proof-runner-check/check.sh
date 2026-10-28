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

emit_status() {
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "status=$1" >> "$GITHUB_OUTPUT"
  echo "proof-runner-check status=$1"
}

dir="${PROOF_RUNNER_WORKDIR:-.}"
cd "$dir" || { emit_status not_run; echo "::error::proof-runner-check: cannot enter $dir — NO CHECK WAS PERFORMED (status=not_run)." >&2; exit 2; }

# projects[i] is built by tools[i] from rundirs[i]: `lake build` resolves
# the package from its working directory, so a Lean project below the
# scan root must be built in its own directory (and must be FOUND there
# first — root-only discovery reported monorepos not_applicable without
# ever invoking Lake). `.lake` is pruned: it holds dependency copies,
# not workspace projects, and building each as a project would multiply
# the work and can fail on dependency default targets.
declare -a projects=() tools=() rundirs=()
# Discovery must fail closed: a find that cannot traverse the tree
# (unreadable directory, I/O error) yields a partial — or empty — set,
# and reporting passed/not_applicable over it would certify projects
# that were never seen. Capture each find's output AND exit status;
# process substitution would discard both the stderr and the status.
disc_ipkg="$(mktemp)" || { emit_status not_run; echo "::error::proof-runner-check: cannot create a temp file — NO CHECK WAS PERFORMED (status=not_run)." >&2; exit 2; }
disc_lake="$(mktemp)" || { emit_status not_run; echo "::error::proof-runner-check: cannot create a temp file — NO CHECK WAS PERFORMED (status=not_run)." >&2; exit 2; }
if ! find . -path ./.git -prune -o -name '*.ipkg' -print > "$disc_ipkg" 2>/dev/null; then
  emit_status not_run
  echo "::error::proof-runner-check: proof-project discovery (find *.ipkg) did not complete — NO CHECK WAS PERFORMED (status=not_run)." >&2
  exit 2
fi
if ! find . -path ./.git -prune -o -path '*/.lake' -prune -o \( -name 'lakefile.lean' -o -name 'lakefile.toml' \) -print > "$disc_lake" 2>/dev/null; then
  emit_status not_run
  echo "::error::proof-runner-check: proof-project discovery (find lakefile.*) did not complete — NO CHECK WAS PERFORMED (status=not_run)." >&2
  exit 2
fi
while IFS= read -r f; do projects+=("$f"); tools+=(idris2); rundirs+=("."); done < <(sort "$disc_ipkg")
while IFS= read -r f; do projects+=("$f"); tools+=(lake); rundirs+=("${f%/*}"); done < <(sort "$disc_lake")
rm -f "$disc_ipkg" "$disc_lake"

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
      echo "Running: (cd ${rundirs[$i]} && lake build)"
      (cd "${rundirs[$i]}" && lake build) \
        || { rc=$?; echo "::error::proof-runner-check: 'lake build' exited $rc in ${rundirs[$i]}."; fail=1; } ;;
  esac
done

if [ "$fail" -eq 1 ]; then
  emit_status failed
  exit 1
fi

emit_status passed
echo "Proof runner passed (${#projects[@]} proof project(s) actually executed and exited 0)."
