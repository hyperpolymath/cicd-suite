#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Negative controls for tests/registry-sq-map.sh: each planted defect in a copy
# of the map must fail the conformance test (exit 1); a missing cross-check
# input must be NOT RUN (exit 2). The unmodified map must pass.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
map=$root/proven/registry/sq-map.tsv
expect() { # NAME WANT [ENV...] -- runs the test on $tmp/map.tsv
  local name=$1 want=$2 rc=0; shift 2
  env SQ_MAP="$tmp/map.tsv" "$@" bash "$root/tests/registry-sq-map.sh" >"$tmp/log" 2>&1 || rc=$?
  [[ $rc == "$want" ]] || { cat "$tmp/log"; echo "FAIL $name: wanted $want, got $rc"; exit 1; }
  echo "ok: $name"
}
cp "$map" "$tmp/map.tsv"; expect 'the committed map conforms' 0
cp "$map" "$tmp/map.tsv"; grep -m1 '^hypatia/' "$map" >> "$tmp/map.tsv"
expect 'a duplicated A5 id fails' 1
cp "$map" "$tmp/map.tsv"; printf 'hypatia/x/y\tSQ-BAD\tmapped\tabsent\tnote\n' >> "$tmp/map.tsv"
expect 'a malformed SQ id fails' 1
cp "$map" "$tmp/map.tsv"; printf 'hypatia/x/y\tunassigned\tmapped\tabsent\tnote\n' >> "$tmp/map.tsv"
expect 'unassigned is refused outside kernel-reason rows' 1
cp "$map" "$tmp/map.tsv"; printf -- '-\tSQ-LOCK-02\tsquabbler-only\t-\tnote\n' >> "$tmp/map.tsv"
expect 'an SQ id both mapped and squabbler-only fails' 1
cp "$map" "$tmp/map.tsv"; printf 'hypatia/x/y\tSQ-LOCK-02\tmapped\tabsent\n' >> "$tmp/map.tsv"
expect 'a row with four fields fails' 1
printf 'SQ-LOCK-01\tFIX\nSQ-ZZZ-99\tFIX\n' > "$tmp/rules.tsv"
cp "$map" "$tmp/map.tsv"; expect 'a table/map mismatch fails' 1 SQUABBLER_RULES="$tmp/rules.tsv"
cp "$map" "$tmp/map.tsv"; expect 'a named but missing table is NOT RUN' 2 SQUABBLER_RULES="$tmp/absent.tsv"
printf 'hypatia/ci_failure_triage/pages_not_enabled\n' > "$tmp/praxis.deed"
cp "$map" "$tmp/map.tsv"; expect 'a praxis column that disagrees with the registry fails' 1 HYPATIA_PRAXIS="$tmp/praxis.deed"
head -n 1 "$map" > "$tmp/map.tsv"; expect 'an empty map is NOT RUN' 2
