#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
repo=$tmp/repo
mkdir -p "$repo/docs"
git -C "$repo" init -q
git -C "$repo" config user.name Fixture
git -C "$repo" config user.email fixture@example.invalid
git -C "$repo" config commit.gpgsign false
git -C "$repo" remote add origin https://github.com/example/documentation.git
printf '%s\n' '= Documentation' >"$repo/README.adoc"
printf '%s\n' '= Index' >"$repo/docs/index.adoc"
git -C "$repo" add README.adoc docs/index.adoc
git -C "$repo" commit -qm fixture
head=$(git -C "$repo" rev-parse HEAD)
profile=$ROOT/tests/fixtures/ci-profiles/docs-data.json
runner=$ROOT/scripts/check-docs-profile-subject.sh
bash "$runner" "$profile" "$repo" "$head" | jq -e '
  .repository=="example/documentation" and (.commit|length)==40 and
  .observation=="document-presence-passed" and (.documents|length)==2
' >/dev/null
mkdir "$tmp/no-jq"
ln -s /usr/bin/dirname "$tmp/no-jq/dirname"
if PATH="$tmp/no-jq" /usr/bin/bash "$runner" "$profile" "$repo" "$head" >"$tmp/log" 2>&1; then
  echo 'FAIL: accepted missing jq' >&2; exit 1
fi
# These controls exercise real checked-out files, source identity and escapes.
expect_failure() {
  if bash "$runner" "$1" "$repo" "$2" >"$tmp/log" 2>&1; then
    echo "FAIL: accepted $3" >&2; exit 1
  fi
}
expect_failure "$profile" 0000000000000000000000000000000000000000 'wrong commit'
jq '.repository="example/wrong"' "$profile" >"$tmp/wrong.json"
expect_failure "$tmp/wrong.json" "$head" 'wrong repository'
rm "$repo/docs/index.adoc"
expect_failure "$profile" "$head" 'missing document'
printf '%s\n' '= Index' >"$repo/docs/index.adoc"
printf 'changed\n' >>"$repo/README.adoc"
expect_failure "$profile" "$head" 'changed source'
git -C "$repo" restore README.adoc
printf '' >"$repo/docs/index.adoc"
expect_failure "$profile" "$head" 'empty document'
git -C "$repo" restore docs/index.adoc
ln -s "$tmp/escape.adoc" "$repo/docs/escape.adoc"
git -C "$repo" add docs/escape.adoc
git -C "$repo" commit -qm symlink
head=$(git -C "$repo" rev-parse HEAD)
jq '.slots.documents=["docs/escape.adoc"]' "$profile" >"$tmp/escape.json"
expect_failure "$tmp/escape.json" "$head" 'symlink escape'
echo 'ok: exact-source document presence, missing/empty/dirty and symlink controls'
