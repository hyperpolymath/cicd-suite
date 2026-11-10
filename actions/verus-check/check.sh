#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Run an installed Verus with planted controls; no source download here.
set -euo pipefail
verifier="${VERUS:-verus}"
command -v "$verifier" >/dev/null || { echo "Verus unavailable: no proof performed" >&2; exit 2; }
[[ $# -gt 0 ]] || { echo "Supply at least one Rust proof file" >&2; exit 2; }
for source in "$@"; do
  [[ -f "$source" && "$source" == *.rs && "$source" != -* ]] || { echo "Invalid proof source: $source" >&2; exit 2; }
done
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/positive.rs" <<'RS'
use vstd::prelude::*;
verus! { pub fn positive() -> (r: u32) ensures r == 2 { 2 } }
RS
cat > "$work/negative.rs" <<'RS'
use vstd::prelude::*;
verus! { pub fn negative() -> (r: u32) ensures r == 0 { 1 } }
RS
if "$verifier" --no-cheating --crate-type lib "$work/negative.rs" >"$work/negative.log" 2>&1; then
  echo "False contract accepted: no caller proof credited" >&2; exit 2
fi
report() {
  grep -qE '^verification results:: [1-9][0-9]* verified, 0 errors$' "$1"
}
if ! "$verifier" --no-cheating --crate-type lib "$work/positive.rs" >"$work/positive.log" 2>&1 || ! report "$work/positive.log"; then
  cat "$work/positive.log" >&2
  echo "Positive control unavailable: no caller proof credited" >&2; exit 2
fi
for source in "$@"; do
  "$verifier" --no-cheating --crate-type lib "$source" >"$work/caller.log" 2>&1 || { cat "$work/caller.log" >&2; exit 1; }
  report "$work/caller.log" || { echo "No nonzero proof report: $source" >&2; exit 2; }
  printf 'verified source: %s\n' "$source"
  cat "$work/caller.log"
done
