#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Read-only proposal check, deliberately not an execution/merge gate.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[[ $# == 1 && -f $1 ]] || { echo 'usage: validate-ci-profile.sh PROFILE.json' >&2; exit 2; }
command -v jq >/dev/null || { echo 'jq required' >&2; exit 2; }
jq -se 'length == 1 and (.[0] | type == "object")' "$1" >/dev/null || {
  echo 'expected one JSON object' >&2; exit 1;
}
# jq otherwise accepts duplicate object keys with last-value-wins semantics.
# Streaming exposes decoded key paths. Remember completed leaves and containers;
# revisiting one (including a parent of a new leaf) means a duplicate member.
jq --stream -s -e '
  reduce .[] as $event ({closed: {}, valid: true};
    if ($event | length) == 2 then
      . as $state | $event[0] as $path |
      .valid = (.valid and all(range(1; ($path | length) + 1);
        . as $n | $state.closed[($path[:$n] | tojson)] != true)) |
      .closed[($path | tojson)] = true
    else .closed[($event[0][:-1] | tojson)] = true end) | .valid
' "$1" >/dev/null || { echo 'duplicate JSON member' >&2; exit 1; }
jq -e -f "$ROOT/catalogue/validate.jq" "$ROOT/catalogue/capabilities.json" >/dev/null
jq -se --slurpfile mothers "$ROOT/profiles/mothers.json" \
  --slurpfile catalogue "$ROOT/catalogue/capabilities.json" \
  -f "$ROOT/profiles/validate.jq" "$1" >/dev/null || {
    echo 'invalid CI profile proposal (identity, capability, obligation, lifecycle or slot)' >&2; exit 1;
  }
echo 'valid CI profile proposal; execution and policy admission remain unqualified'
