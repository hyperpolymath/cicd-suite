#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
validate() {
  jq -e --slurpfile mothers "$ROOT/profiles/mothers.json" '
    def exact($k): type == "object" and keys == ($k | sort);
    def text: type == "string" and test("[^[:space:]]");
    exact(["schema_version", "stage", "inspected_on", "qualification", "candidates"]) and
    .schema_version == 1 and .stage == "proposal" and .qualification == "not-run" and
    (.inspected_on | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) and
    (.candidates | type == "array" and length > 0 and length <= 6) and
    ([.candidates[].repository] | length == (unique | length)) and
    all(.candidates[];
      exact(["repository", "mother", "snapshot_commit", "evidence_paths", "reason", "open_questions"]) and
      (.repository | test("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$")) and
      (.mother as $m | [$mothers[0].mothers[].id] | index($m) != null) and
      (.snapshot_commit | test("^[a-f0-9]{40}$")) and
      (.evidence_paths | type == "array" and length > 0 and all(.[]; text)) and
      (.reason | text) and
      (.open_questions | type == "array" and length > 0 and all(.[]; text)))
  ' "$1" >/dev/null
}
validate "$ROOT/profiles/pilot.json"
for mutation in \
  '.qualification="passed"' \
  '.stage="enforcing"' \
  '.candidates += [.candidates[0]]' \
  '.candidates[0].snapshot_commit="main"' \
  '.candidates[0].mother="unknown-v1"' \
  '.candidates[0].open_questions=[]' \
  '.candidates[0].enabled=true'; do
  jq "$mutation" "$ROOT/profiles/pilot.json" >"$tmp/pilot.json"
  if validate "$tmp/pilot.json"; then
    echo "FAIL: accepted pilot mutation: $mutation" >&2; exit 1
  fi
done
echo 'ok: proposed pilot manifest and seven negative controls (no remote qualification)'
