#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
validator=$ROOT/scripts/validate-ci-profile.sh
fixtures=$ROOT/tests/fixtures/ci-profiles
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
count=0
for fixture in "$fixtures"/*.json; do
  bash "$validator" "$fixture"
done
expect_failure() {
  if bash "$validator" "$tmp/profile.json" >"$tmp/log" 2>&1; then
    echo "FAIL: accepted $1" >&2; exit 1
  fi
  count=$((count + 1))
  echo "ok: rejected $1"
}
mutate() {
  jq "$2" "$fixtures/${3:-rust}.json" >"$tmp/profile.json"
  expect_failure "$1"
}
mutate 'missing required capability' '.capabilities |= map(select(.id != "secret-scan"))'
mutate 'required capability demoted' '(.capabilities[] | select(.id == "rust-ci")).obligation = "advisory"'
mutate 'required capability exempted' '.capabilities[0].obligation = "not-applicable"'
mutate 'unknown capability' '.capabilities += [{id:"invented",obligation:"required"}]'
mutate 'placeholder as assurance' '.capabilities += [{id:"prat",obligation:"required"}]'
mutate 'advisory as required' '.capabilities += [{id:"badges",obligation:"required"}]'
mutate 'duplicate capability' '.capabilities += [.capabilities[0]]'
mutate 'unknown mother' '.mother = "invented-v1"'
mutate 'unknown slot' '.slots.run = "echo passed"'
mutate 'missing slot' 'del(.slots.msrv)'
mutate 'wrong slot type' '.slots.msrv = 1.85'
mutate 'floating version' '.slots.msrv = "stable"'
mutate 'newline in version' '.slots.msrv = "1.85\n"'
mutate 'newline in path' '.slots.root = "crates/library\n"'
mutate 'expression in version' '.slots.msrv = "${{ github.ref }}"'
mutate 'shell in root' '.slots.root = "$(id)"'
mutate 'absolute root' '.slots.root = "/tmp/project"'
mutate 'parent traversal' '.slots.root = "crates/../project"'
mutate 'Windows traversal' '.slots.root = "C:\\project"'
mutate 'URL instead of repository' '.repository = "https://github.com/example/project"'
mutate 'unsupported schema' '.schema_version = 2'
mutate 'self promotion' '.stage = "qualified"'
mutate 'permission extension' '.permissions = {contents:"write"}'
mutate 'missing lifecycle' '.lifecycles = ["validate"]'
mutate 'duplicate lifecycle' '.lifecycles += ["validate"]'
mutate 'release lifecycle' '.lifecycles += ["release"]'
mutate 'empty capability list' '.capabilities = []'
mutate 'empty Julia matrix' '.slots.julia_versions = []' julia
mutate 'duplicate Julia matrix' '.slots.julia_versions = ["1.9", "1.9"]' julia
mutate 'document path escape' '.slots.documents = ["../README.adoc"]' docs-data
mutate 'no documents' '.slots.documents = []' docs-data
mutate 'scalar profile' 'true'
mutate 'array profile' '[.]'
# Positive extensions must preserve their honest advisory classification.
jq '.capabilities += [{id:"badges",obligation:"advisory"}]' "$fixtures/rust.json" >"$tmp/profile.json"
bash "$validator" "$tmp/profile.json"
# Duplicate keys must be rejected before jq normalises the object. These
# otherwise-valid examples include escaped names and disjoint container members.
for duplicate in \
  '"stage":"qualified",' \
  '"sta\u0067e":"qualified",' \
  '"slots":{},' \
  '"slots":{"other":"discarded"},' \
  '"capabilities":[{"id":"invented","obligation":"required"}],'; do
  { printf '{%s\n' "$duplicate"; tail -n +2 "$fixtures/rust.json"; } >"$tmp/profile.json"
  expect_failure "duplicate JSON member: $duplicate"
done
sed 's/"root":/"root":"discarded", "root":/' "$fixtures/rust.json" >"$tmp/profile.json"
expect_failure 'nested duplicate member'
cat "$fixtures/rust.json" "$fixtures/rust.json" >"$tmp/profile.json"
expect_failure 'multiple JSON documents'
printf '{"broken":' >"$tmp/profile.json"
expect_failure 'malformed JSON'
: >"$tmp/profile.json"
expect_failure 'empty input'
echo "ok: three profile fixtures, advisory extension and $count negative controls"
