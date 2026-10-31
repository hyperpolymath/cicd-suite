#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
builder=$ROOT/scripts/build-assurance-matrix.sh
bash "$builder" --check
mkdir "$tmp/tree"
cp -a "$ROOT/catalogue" "$ROOT/docs" "$ROOT/actions" "$ROOT/tests" "$ROOT/.github" "$tmp/tree/"
fixture=$tmp/tree
CATALOGUE_ROOT=$fixture bash "$builder" --check >/dev/null
reject() {
    if CATALOGUE_ROOT=$fixture bash "$builder" --check > "$tmp/log" 2>&1; then
        echo "accepted invalid assurance case: $1" >&2; exit 1
    fi
    echo "ok: refused $1"
}
mutate() {
    jq "$2" "$ROOT/catalogue/assurance.json" > "$fixture/catalogue/assurance.json"
    reject "$1"
    cp "$ROOT/catalogue/assurance.json" "$fixture/catalogue/assurance.json"
}
mutate 'omitted capability' '.capabilities|=.[1:]'
mutate 'duplicate capability' '.capabilities+=[.capabilities[0]]'
mutate 'unknown evidence class' '.capabilities[0].coverage="certified"'
mutate 'nonexistent control path' '.capabilities[0].test_paths=["tests/absent.sh"]'
mutate 'path traversal' '.capabilities[0].test_paths=["tests/../../outside"]'
mutate 'false receipt identity' '.capabilities[0].consumer_receipts[0].subject_sha="main"'
mutate 'empty coverage with linked tests' '.capabilities[0].coverage="not-assessed"'
mutate 'placeholder promoted to evidence' '(.capabilities[]|select(.coverage=="placeholder"))|=(.coverage="controls-linked"|.test_paths=["tests/pass-on-absence.sh"])'
mutate 'unknown schema' '.schema_version=9'
printf 'stale\n' > "$fixture/docs/CAPABILITY-ASSURANCE.adoc"
reject 'stale generated matrix'
CATALOGUE_ROOT=$fixture bash "$builder" >/dev/null
cmp "$ROOT/docs/CAPABILITY-ASSURANCE.adoc" "$fixture/docs/CAPABILITY-ASSURANCE.adoc"
echo 'ok: complete evidence inventory, deterministic matrix and ten negative controls'
