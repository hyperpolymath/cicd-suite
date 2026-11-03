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

# A purported proof of an empty requirement set passing must not typecheck.
# The unmodified package above must compile first, so a negative result is
# attributable to this single, well-formed contradictory declaration.
cat >> "$tmp/src/Assurance/Verdict.idr" <<'BAD'
counterfeitEmptyPass : decide [] = Passed
counterfeitEmptyPass = Refl
BAD
if (cd "$tmp" && idris2 --build assurance-kernel.ipkg) >"$tmp/negative.log" 2>&1; then
  echo "FAIL: Idris2 accepted a proof that empty requirements pass" >&2
  exit 1
fi
echo "ok: real compiler rejected contradictory empty-pass proof"
