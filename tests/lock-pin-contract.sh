#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sha=3d3c42e5aac5ba805825da76410c181273ba90b1
fixture() {
    printf 'version: %s\ndependencies:\n  actions/checkout@%s:\n    ref: "%s"\n    commit: "%s"\n' "$1" "$sha" "$2" "$3" > "$tmp/lock.yml"
}
assert_case() {
    local name=$1 expected=$2 rc=0
    bash "$root/scripts/check-lock-pin-contract.sh" "$tmp/lock.yml" > "$tmp/log" 2>&1 || rc=$?
    [[ $rc == "$expected" ]] || { cat "$tmp/log"; echo "FAIL $name: wanted $expected got $rc"; exit 1; }
    echo "ok: $name"
}
# These minimal records reproduce the checkout representation observed in
# metadatastician/standards actions.lock at fad242d35291de1898242d6737ba02b74a59a2f2
# and the corrected main at 1725bebd3773ea25627479f813283abf1c497a85 respectively.
# They are representations only: not whole immutable workflow/lock snapshots.
fixture v0.0.3 "$sha" "sha1-$sha"
assert_case 'historical runner-invalid raw SHA ref' 1
fixture v0.0.3 v7.0.1 "sha1-$sha"
assert_case 'corrected reviewed tag and matching SHA' 0
fixture v0.0.2 v7.0.1 "sha1-$sha"
assert_case 'v0.0.2 representation supported' 0
fixture v0.0.3 v7.0.1 sha1-ffffffffffffffffffffffffffffffffffffffff
assert_case 'immutable dependency key mismatch' 1
fixture v0.0.3 v7.0.1 "$sha"
assert_case 'missing commit algorithm rejected' 1
fixture v0.0.3 '' "sha1-$sha"
assert_case 'empty ref rejected' 1
fixture v0.0.3 null "sha1-$sha"
# The string "null" is a legal ref name. Use actual YAML null for absence.
sed -i 's/ref: "null"/ref: null/' "$tmp/lock.yml"
assert_case 'null ref rejected' 1
fixture v99 v7.0.1 "sha1-$sha"
assert_case 'unknown schema is uninspected, not clean' 2
printf 'version: v0.0.3\ndependencies: {}\n' > "$tmp/lock.yml"
assert_case 'empty population gives no assurance' 2
printf 'version: v0.0.3\ndependencies: []\n' > "$tmp/lock.yml"
assert_case 'non-mapping dependencies rejected' 2
printf 'version: v0.0.3\ndependencies: [\n' > "$tmp/lock.yml"
assert_case 'malformed YAML rejected' 2
rm "$tmp/lock.yml"
assert_case 'missing lock is not a pass' 2

# Reusable-workflow edges (standards#1290, the squabbler's self_sha_lock_records,
# RefOk in src/Proven/Lock/Model.idr). A ref may repeat its key's SHA only when
# a workflow beside the lock calls that key as a job-level reusable.
edge=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
edge_lock() { # USES_YAML
    printf 'version: v0.0.3\ndependencies:\n  other/repo@%s:\n    ref: "%s"\n    commit: "sha1-%s"\n%s' \
        "$edge" "$edge" "$edge" "$1" > "$tmp/lock.yml"
}
caller() { # USES_LINE
    printf 'on: push\njobs:\n  call:\n    uses: %s\n' "$1" > "$tmp/caller.yml"
}
edge_lock '    uses: []
'
caller "other/repo/.github/workflows/x.yml@$edge"
assert_case 'job-level caller makes a raw-SHA ref a reusable edge' 0
caller "Other/Repo/.github/workflows/x.yml@${edge^^}"
assert_case 'caller matching is case-insensitive on owner, repo and SHA' 0
edge_lock '    uses:
      - "actions/upload-artifact@cccccccccccccccccccccccccccccccccccccccc"
'
rm -f "$tmp/caller.yml"
assert_case 'a uses: list alone is a composite, not a reusable edge' 1
caller "other/repo/.github/workflows/x.yml@dddddddddddddddddddddddddddddddddddddddd"
assert_case 'a caller of another SHA does not exempt this key' 1
edge_lock '    uses:
      bad: shape
'
caller "other/repo/.github/workflows/x.yml@$edge"
assert_case 'a malformed uses: never qualifies as an edge' 1
edge_lock '    uses: []
'
printf 'jobs: [\n' > "$tmp/caller.yml"
assert_case 'an unparsable workflow leaves the caller set unknown' 2
rm -f "$tmp/caller.yml"
