#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Compiler evidence for the proven lock kernel, in the style of
# tests/assurance-kernel.sh:
#   1. the package builds, so the theorems in src/Proven/Lock/Model.idr and the
#      controls in src/Proven/Lock/Controls.idr typecheck, the judge is total,
#      and the compiler's own evaluation finds the good fixture CONSISTENT;
#   2. each counterfeit below, appended to an isolated copy of Controls.idr,
#      is REJECTED by the compiler, with a diagnostic that names it.
# No compiler means NOT RUN (exit 2), never a pass.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v idris2 >/dev/null 2>&1; then
  echo "proven-lock-proofs: idris2 missing; NOT RUN" >&2
  exit 2
fi
cd "$root"
idris2 --version
idris2 --build proven-lock.ipkg

# The trusted base is exactly the two named axioms. Any other escape hatch in
# the kernel sources fails this test.
hatches=$(grep -nE 'believe_me|assert_total|assert_smaller|idris_crash|%unsafe|unsafePerformIO' \
            src/Proven/Lock/*.idr \
          | grep -vE '^[^:]+:[0-9]+:(\|\|\||--)' \
          | sed -E 's/^([^:]+):[0-9]+:/\1:/' \
          | grep -vxF -e 'src/Proven/Lock/Model.idr:stringEqSound x _ _ = believe_me (the (x = x) Refl)' \
                      -e 'src/Proven/Lock/Model.idr:stringEqRefl _ = believe_me Oh' || true)
if [[ -n $hatches ]]; then
  echo "FAIL: escape hatch outside the named axioms:" >&2
  echo "$hatches" >&2
  exit 1
fi
echo "ok: trusted base is stringEqSound and stringEqRefl only"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
cp -R src "$tmp/src"
cp proven-lock.ipkg "$tmp/"
if ! (cd "$tmp" && idris2 --build proven-lock.ipkg) >"$tmp/baseline.log" 2>&1; then
  echo "FAIL: isolated baseline did not compile before mutation" >&2
  cat "$tmp/baseline.log" >&2
  exit 1
fi

reject() {
  local name="$1" type="$2" term="$3"
  cp "$root/src/Proven/Lock/Controls.idr" "$tmp/src/Proven/Lock/Controls.idr"
  printf '\n%s : %s\n%s = %s\n' "$name" "$type" "$name" "$term" \
    >> "$tmp/src/Proven/Lock/Controls.idr"
  if (cd "$tmp" && idris2 --build proven-lock.ipkg) >"$tmp/negative.log" 2>&1; then
    echo "FAIL: the compiler accepted the counterfeit $name" >&2
    exit 1
  fi
  if ! grep -Fq "$name" "$tmp/negative.log" || ! grep -Eq 'Error' "$tmp/negative.log"; then
    echo "FAIL: the build failed, but not with a diagnosed $name rejection" >&2
    cat "$tmp/negative.log" >&2
    exit 1
  fi
  echo "ok: the compiler rejected $name"
}

# A self-SHA leaf presented as a named ref (svalinn run 40108154356).
reject counterfeitSelfShaNamed \
  'RefOk [] (Controls.leaf Controls.shaB)' 'NamedRef Refl Oh Oh'
# The same leaf presented as a caller edge with no job-level caller.
reject counterfeitSelfShaCaller \
  'RefOk [] (Controls.leaf Controls.shaB)' 'CallerEdge Refl Oh Oh Here Oh'
# An entry that drops the composite-reached key (run 35786094563).
reject counterfeitDropped \
  'EdgesExact Controls.probe Controls.wfNode [] [Controls.checkoutKey]' \
  'MkEdgesExact (\k, r => Here) [Reached (ByStep Here)]'
# A blind [] entry for a workflow that reaches keys.
reject counterfeitBlindEmpty \
  'EdgesExact Controls.probe Controls.wfNode [] []' \
  'MkEdgesExact (\k, r => absurd r) []'
# A stale key listed although nothing reaches or calls it.
reject counterfeitStaleKey \
  'All (Allowed Controls.probe Controls.wfNode []) ["y/stale@v1"]' \
  '[Reached (ByStep Here)]'
# The judge evaluated by the compiler cannot be made to say otherwise.
reject counterfeitGoodRejected \
  'isConsistent (judge Controls.good) = False' 'Refl'
reject counterfeitEmptyLockPasses \
  'isConsistent (judge (MkFacts Controls.probe [Controls.wf] [MkEntry ".github/workflows/a.yml" []] [] [] Nothing)) = True' \
  'Refl'
echo "proven-lock-proofs: all controls held"
