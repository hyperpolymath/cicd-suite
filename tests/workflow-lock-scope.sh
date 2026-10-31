#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
trap 'rc=$?; echo "::error::lock scope regression failed at line $LINENO (exit $rc)"; exit "$rc"' ERR
ROOT=$(cd "$(dirname "$0")/.." && pwd)
builder=$ROOT/scripts/check-workflow-lock-scope.sh
bash "$builder"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/base"
cp -a "$ROOT/.github" "$ROOT/config" "$ROOT/actions" "$tmp/base/"
yq -o=json '.' "$tmp/base/.github/workflows/actions.lock" > "$tmp/lock.json"
# Assert a coverage failure (1), never a tool/parse failure (2).
reject() {
    local name=$1 rc=0
    SCOPE_ROOT="$tmp/tree" bash "$builder" > "$tmp/log" 2>&1 || rc=$?
    [[ $rc == 1 ]] || { cat "$tmp/log"; echo "FAIL $name: expected coverage failure 1, got $rc" >&2; exit 1; }
    echo "ok: refused $name"
}
# Restore a pristine isolated tree for each mutation.
stage() { rm -rf "$tmp/tree"; cp -a "$tmp/base" "$tmp/tree"; }
# Apply the supplied constant jq mutation, then require rejection.
lock_mutant() {
    local label=$1 filter=$2
    stage
    jq "$filter" "$tmp/lock.json" > "$tmp/tree/.github/workflows/actions.lock"
    reject "$label"
}
lock_mutant 'omitted managed workflow key' 'del(.workflows[".github/workflows/code-hygiene-self-test.yml"])'
lock_mutant 'dropped direct dependency record' 'del(.dependencies["actions/checkout@v7.0.1"])'
lock_mutant 'dropped composite closure edge' '.workflows[".github/workflows/code-hygiene-self-test.yml"] |= map(select(startswith("hyperpolymath/deed-ecosystem@")|not))'
lock_mutant 'missing declared remote edge' '.dependencies |= with_entries(if (.key|startswith("hyperpolymath/deed-ecosystem@")) then .value.uses=["owner/missing@v1"] else . end) | .dependencies["owner/missing@v1"]={ref:"v1",commit:"sha1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",owner_id:1,repo_id:2}'
jq -e '.dependencies["owner/missing@v1"].ref=="v1" and (.dependencies["owner/missing@v1"].commit|test("^sha1-[a-f0-9]{40}$"))' "$tmp/tree/.github/workflows/actions.lock" >/dev/null
grep -Fq 'missing lock coverage for owner/missing@v1' "$tmp/log"
stage
jq '.workflows += [.workflows[0]]' "$tmp/base/config/workflow-lock-scope.json" > "$tmp/tree/config/workflow-lock-scope.json"
reject 'duplicate scope row'
stage
jq '.workflows[0].mode="ignore"' "$tmp/base/config/workflow-lock-scope.json" > "$tmp/tree/config/workflow-lock-scope.json"
reject 'unknown scope mode'
stage
printf 'name: Unreviewed\njobs: {}\n' > "$tmp/tree/.github/workflows/unreviewed.yml"
reject 'new unscoped workflow'
stage
file=$tmp/tree/.github/workflows/secret-scanner.yml
yq -o=json '.' "$file" | jq '.jobs.scan.uses="hyperpolymath/cicd-suite/.github/workflows/secret-scanner-reusable.yml@main"' > "$tmp/changed.json"
cp "$tmp/changed.json" "$file"
reject 'floating reusable in immutable workflow'
stage
mv "$tmp/tree/actions/manifest-check/action.yml" "$tmp/tree/actions/manifest-check/action.yaml"
SCOPE_ROOT="$tmp/tree" bash "$builder" >/dev/null
echo 'ok: action.yaml local composite is inspected'
rm "$tmp/tree/actions/manifest-check/action.yaml"
rc=0
SCOPE_ROOT="$tmp/tree" bash "$builder" > "$tmp/log" 2>&1 || rc=$?
[[ $rc == 2 ]] || { echo "missing metadata returned $rc rather than unavailable (2)" >&2; exit 1; }
echo 'ok: missing action.yml and action.yaml remains unavailable'
echo 'ok: scope baseline, eight coverage mutants and two metadata-name controls'
