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
reject() {
    local name=$1 rc=0
    SCOPE_ROOT="$tmp/tree" bash "$builder" > "$tmp/log" 2>&1 || rc=$?
    [[ $rc == 1 ]] || { cat "$tmp/log"; echo "FAIL $name: expected coverage failure 1, got $rc" >&2; exit 1; }
    echo "ok: refused $name"
}
stage() { rm -rf "$tmp/tree"; cp -a "$tmp/base" "$tmp/tree"; }
lock_mutant() {
    stage
    jq "$2" "$tmp/lock.json" > "$tmp/tree/.github/workflows/actions.lock"
    reject "$1"
}
lock_mutant 'omitted managed workflow key' 'del(.workflows[".github/workflows/code-hygiene-self-test.yml"])'
lock_mutant 'dropped direct dependency record' 'del(.dependencies["actions/checkout@v7.0.1"])'
lock_mutant 'dropped composite closure edge' '.workflows[".github/workflows/code-hygiene-self-test.yml"] |= map(select(startswith("hyperpolymath/deed-ecosystem@")|not))'
lock_mutant 'missing declared remote edge' '.dependencies |= with_entries(if (.key|startswith("hyperpolymath/deed-ecosystem@")) then .value.uses=["owner/missing@v1"] else . end)'
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
echo 'ok: scope baseline and eight missing-key/edge/boundary mutants'
