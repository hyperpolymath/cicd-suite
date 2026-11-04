#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
# Bounded crash/inventory/report controls, not a precision benchmark.
# Usage: bash scanner-adversarial.sh /absolute/pons /absolute/panic-attack
set -euo pipefail
if [[ $# != 2 || ! -x $1 || ! -x $2 ]]; then
  echo 'NO CHECK PERFORMED: provide both scanner executables' >&2
  exit 2
fi
for tool in jq timeout awk realpath sha256sum; do
  command -v "$tool" >/dev/null || { echo "NO CHECK PERFORMED: missing $tool" >&2; exit 2; }
done
pons=$(realpath "$1")
panic=$(realpath "$2")
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir "$root/empty"
: > "$root/cases.jsonl"
run() {
  local label=$1 expected=$2 machine=$3 rc=0 start elapsed
  shift 3
  start=$EPOCHREALTIME
  timeout --kill-after=1 10 "$@" > "$root/stdout" 2> "$root/stderr" || rc=$?
  elapsed=$(awk -v start="$start" -v stop="$EPOCHREALTIME" 'BEGIN {printf "%.6f", stop-start}')
  if [[ ",$expected," != *",$rc,"* ]]; then
    echo "FAIL: $label: exit $rc, expected $expected" >&2
    cat "$root/stderr" >&2
    exit 1
  fi
  if [[ $machine == yes ]]; then
    # Slurp also rejects multiple JSON values, not just invalid JSON syntax.
    jq -e -s 'length == 1 and (.[0] | type == "object")' "$root/stdout" >/dev/null || {
      echo "FAIL: $label: expected one JSON object" >&2; exit 1;
    }
  fi
  jq -nc --arg case "$label" --argjson exit "$rc" --argjson seconds "$elapsed" \
    '{case:$case,exit:$exit,seconds:$seconds}' >> "$root/cases.jsonl"
}
run pons-empty-refused 2 yes "$pons" scan "$root/empty" --format json --fail-on-skips
run panic-empty-refused 2 yes "$panic" assail "$root/empty" --headless --fail-on-incomplete
printf 'def answer():\n    return 42\n' > "$root/control.py"
run pons-positive 0 yes "$pons" scan "$root/control.py" --format json --fail-on-skips
cp "$root/stdout" "$root/valid.json"
run valid-report 0 no "$pons" validate-report "$root/valid.json"
for field in schema_version tool execution scanned findings; do
  case "$field" in
    schema_version) value='"wrong"' ;;
    tool|scanned) value=null ;;
    execution) value=false ;;
    findings) value='"not-an-array"' ;;
  esac
  jq --arg field "$field" --argjson value "$value" '.[$field]=$value' \
    "$root/valid.json" > "$root/report.json"
  run "malformed-$field" 2 no "$pons" validate-report "$root/report.json"
done
# Fully specified 31-bit LCG, independent of awk's implementation-specific RNG.
# Bash arithmetic stays below signed 64-bit range. NUL is written directly;
# generated source is never evaluated or executed.
state=1371
# Literal PHP variable is scanner input, not shell code.
# shellcheck disable=SC2016
tokens=('(' ')' '{' '}' 'if' 'return' '$x' '"' '\n' 'λ' '\0' ';' 'await')
: > "$root/input-sha256.txt"
for ((i=0; i<64; i++)); do
  suffix=py
  ((i % 2 == 0)) || suffix=php
  source="$root/mutation.$suffix"
  : > "$source"
  [[ $suffix != php ]] || printf '<?php\n' >> "$source"
  for ((j=0; j<8+i*8; j++)); do
    state=$(((1103515245 * state + 12345) % 2147483648))
    printf '%b ' "${tokens[state % ${#tokens[@]}]}" >> "$source"
  done
  digest=$(sha256sum "$source")
  printf '%s\n' "${digest%% *}" >> "$root/input-sha256.txt"
  run "parser-$i" 0,1,2 yes "$pons" scan "$source" --format json --fail-on-skips
done
jq -ns --slurpfile cases "$root/cases.jsonl" --rawfile hashes "$root/input-sha256.txt" \
  '{seed:1371,generator:"lcg-1103515245-12345-mod-2^31",timeout_seconds:10,
    kill_grace_seconds:1,claim:"bounded parser and report/inventory controls only",
    parser_input_sha256:($hashes | split("\n") | map(select(length>0))),cases:$cases}'
