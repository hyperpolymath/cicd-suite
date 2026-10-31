#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Exercise the exact compatibility-job shell parsed from the workflow YAML.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
command -v yq >/dev/null || { echo 'mikefarah yq v4 is required' >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
program=$(yq -r '.jobs["supplemental-results"].steps[0].run' "$root/.github/workflows/secret-scanner-reusable.yml")
[[ -n $program && $program != null ]] || { echo 'receipt validator missing' >&2; exit 2; }
printf '%s\n' "$program" > "$tmp/validate.sh"
sha=0123456789abcdef0123456789abcdef01234567
assert_receipt() {
    local want=$1 label=$2 detector=$3 upstream=$4 actual=${5-$sha} expected=${6-$sha} rc=0
    DETECTOR_STATUS=$detector UPSTREAM_RESULT=$upstream SUBJECT_SHA=$actual EXPECTED_SHA=$expected \
        bash "$tmp/validate.sh" >"$tmp/output" 2>&1 || rc=$?
    [[ $rc == "$want" ]] || { cat "$tmp/output"; echo "FAIL $label: wanted $want got $rc"; exit 1; }
    echo "ok: $LANGUAGE $label"
}
for language in rust shell; do
    export LANGUAGE=$language
    assert_receipt 0 'completed passing detector' 0 success
    assert_receipt 0 'passing detector despite another failed scan component' 0 failure
    assert_receipt 1 'finding stays red' 1 failure
    assert_receipt 2 'tool error stays non-passing' 2 failure
    assert_receipt 2 'timeout stays non-passing' 124 failure
    assert_receipt 2 'missing receipt is not green' '' success
    assert_receipt 2 'cancelled upstream is not green' 0 cancelled
    assert_receipt 2 'skipped upstream is not green' 0 skipped
    assert_receipt 2 'wrong subject is not green' 0 success ffffffffffffffffffffffffffffffffffffffff
    assert_receipt 2 'missing expected SHA is not green' 0 success "$sha" ''
done
LANGUAGE=unknown assert_receipt 2 'unknown detector is refused' 0 success
