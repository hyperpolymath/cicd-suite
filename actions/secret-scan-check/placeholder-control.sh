#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Exact curl placeholder control; all credential controls are synthetic,
# assembled at runtime, and never printed or uploaded.
set -euo pipefail
scanner=${GITLEAKS_BIN:?}
config=${1:?usage: placeholder-control.sh CONFIG}
command -v jq >/dev/null || { echo '::error::jq unavailable for detector identity controls'; exit 2; }
fixture_dir=$(mktemp -d)
trap 'rm -rf -- "$fixture_dir"' EXIT
credential=$(printf '%s%s' Q7mN2aR9vB4cD6eF8 gH1jK3pL5sT0uV2wX4z)
for fixture in exact credential prefix suffix; do
    case "$fixture" in
        exact) value=your-key-here; expected=0 ;;
        credential) value=$credential; expected=10 ;;
        prefix) value=${credential}your-key-here; expected=10 ;;
        suffix) value=your-key-here${credential}; expected=10 ;;
    esac
    mkdir "$fixture_dir/$fixture"
    printf '%s\n' '```sh' \
        "curl https://example.invalid/api -H \"Authorization: Bearer $value\"" \
        '```' > "$fixture_dir/$fixture/V1.2_DEPLOYMENT_GUIDE.md"
    rc=0
    timeout --kill-after=5s 15s "$scanner" dir "$fixture_dir/$fixture" \
        --config "$config" --redact=100 --no-banner --exit-code 10 \
        --report-format json --report-path "$fixture_dir/$fixture-report.json" >/dev/null 2>&1 || rc=$?
    [[ $rc == "$expected" ]] || {
        echo "::error::curl placeholder control $fixture expected $expected, got $rc; no trustworthy scan"
        exit 2
    }
    if [[ "$expected" == 0 ]]; then
        jq -e 'type == "array" and length == 0' "$fixture_dir/$fixture-report.json" >/dev/null || exit 2
    else
        jq -e 'type == "array" and any(.[]; .RuleID == "curl-auth-header")' "$fixture_dir/$fixture-report.json" >/dev/null || {
            echo "::error::curl placeholder control $fixture did not produce the expected detector finding"
            exit 2
        }
    fi
done
echo 'curl placeholder controls passed (exact literal accepted; credential, prefix and suffix refused)'
