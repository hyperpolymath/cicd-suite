#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Manual, read-only qualification against reviewed immutable public subjects.
# A satisfied negative control retains the consumer's FAILED receipt.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
[[ $# == 1 ]] || { echo 'usage: assurance-real-canaries.sh NEW_OUTPUT_DIR' >&2; exit 2; }
output=$1
mkdir "$output"
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
# shellcheck source=scripts/assurance-github.sh
source "$root/scripts/assurance-github.sh"
if ! assurance_build "$build"; then
    echo 'real compiler/source unavailable; canaries NOT RUN' >&2
    exit 2
fi
observe() {
    local name=$1 policy=$2 digest=$3 expected=$4 expected_exit=$5 expected_states=$6 status
    set +e
    assurance_collect "$root/$policy" "$digest" "$output/$name" >"$output/$name.stdout.json"
    status=$?
    set -e
    [[ $status == "$expected_exit" ]] ||
        { echo "$name: unexpected collector exit $status; qualification incomplete" >&2; exit 1; }
    jq -e --arg expected "$expected" --arg digest "$digest" \
       --arg source "$ASSURANCE_SOURCE_SHA" --argjson states "$expected_states" '
       .verdict == $expected
       and .kernel_verdict == (if $expected=="PASSED" then "PASSED" else "BLOCKED" end)
       and .policy_sha256 == $digest and .source_commit == $source
       and ([.observations[].state]|sort) == ($states|sort)' \
       "$output/$name/receipt.json" >/dev/null ||
        { echo "$name: expected real observation was not established" >&2; exit 1; }
    printf '%s: consumer verdict %s retained; actual compiled kernel executed\n' "$name" "$expected"
}
observe suite-a96 config/assurance-canaries/suite-a96.json \
    8b7690f38d1b89a97399db96537fe37311e56cc73dc2828f7fe6f82ec2b7d9c6 \
    PASSED 0 '["PASSED"]'
observe echidna-3f-chapel config/assurance-canaries/echidna-3f-chapel.json \
    cfe90f04a14f6937a7ca41ee39119c256926058e96f3827b07f9e3570b033fd9 \
    FAILED 1 '["PASSED","PASSED","PASSED","FAILED"]'
jq -s '{
  schema:"proven-cicd/github-execution-canary-observations/v1",
  category:"experimental",
  observation:"expected_real_subject_results_recorded",
  promotion_authorized:false,
  receipts:.
}' "$output/suite-a96/receipt.json" "$output/echidna-3f-chapel/receipt.json" \
   >"$output/observations.json"
