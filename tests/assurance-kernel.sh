#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# The positive compilation and the rejected contradictory theorem are
# separate evidence. No compiler means NOT RUN (exit 2), never a pass.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v idris2 >/dev/null 2>&1; then
  echo "assurance-kernel: idris2 missing; NOT RUN" >&2
  exit 2
fi
cd "$root"
idris2 --version
idris2 --build assurance-kernel.ipkg

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -R src "$tmp/src"
cp assurance-kernel.ipkg "$tmp/assurance-kernel.ipkg"
# Baseline the copied tree before injecting the contradiction; a broken copy
# must not masquerade as a valid negative proof observation.
if ! (cd "$tmp" && idris2 --build assurance-kernel.ipkg) >"$tmp/baseline.log" 2>&1; then
  echo "FAIL: isolated baseline did not compile before mutation" >&2
  cat "$tmp/baseline.log" >&2
  exit 1
fi

# Each contradictory theorem is compiled independently against the baseline.
# A stale error from one mutation must not count as rejection of another one.
reject_proof() {
  local theorem="$1" proposition="$2"
  cp "$root/src/Assurance/Verdict.idr" "$tmp/src/Assurance/Verdict.idr"
  printf '\n%s : %s\n%s = Refl\n' "$theorem" "$proposition" "$theorem" \
    >> "$tmp/src/Assurance/Verdict.idr"
  if (cd "$tmp" && idris2 --build assurance-kernel.ipkg) >"$tmp/negative.log" 2>&1; then
    echo "FAIL: Idris2 accepted the contradictory proof $theorem" >&2
    exit 1
  fi
  # A generic failing build is not a negative-control result. Demand both
  # a real Idris2 diagnostic and its attribution to this false theorem.
  if ! grep -Fq "$theorem" "$tmp/negative.log" ||
     ! grep -Eq 'Error|error' "$tmp/negative.log"; then
    echo "FAIL: negative build was not a diagnosed $theorem rejection" >&2
    cat "$tmp/negative.log" >&2
    exit 1
  fi
  echo "ok: real compiler rejected $theorem"
}

reject_proof counterfeitEmptyPass 'decide [] = Passed'
reject_proof counterfeitPendingAdvisoryPass \
  'decide [MkObservation Mandatory Applies CompletedSuccess CurrentRevision AdmissionVerified, MkObservation Advisory Applies NeverStarted CurrentRevision AdmissionVerified] = Passed'
reject_proof counterfeitStaleAdvisoryPass \
  'decide [MkObservation Mandatory Applies CompletedSuccess CurrentRevision AdmissionVerified, MkObservation Advisory Applies CompletedSuccess PreviousRevision AdmissionVerified] = Passed'
