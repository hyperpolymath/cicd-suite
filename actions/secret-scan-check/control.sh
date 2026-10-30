#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Live positive/negative detector controls with the effective configuration.
# Synthetic, never-issued token is assembled, never stored as a credential.
set -euo pipefail
scanner=${GITLEAKS_BIN:?}
config=${1:-$(cd "$(dirname "$0")/../.." && pwd)/config/gitleaks/estate-baseline.toml}
rc=0
printf 'A clean control with no credential.\n' | timeout --kill-after=5s 15s "$scanner" stdin \
    --config "$config" --redact=100 --no-banner --exit-code 10 >/dev/null 2>&1 || rc=$?
[[ $rc == 0 ]] || { echo '::error::clean scanner control failed'; exit 2; }
rc=0
printf '%s_%s\n' ghp Q7mN2aR9vB4cD6eF8gH1jK3pL5sT0uV2wX4z | timeout --kill-after=5s 15s "$scanner" stdin \
    --config "$config" --redact=100 --no-banner --exit-code 10 >/dev/null 2>&1 || rc=$?
[[ $rc == 10 ]] || { echo "::error::planted credential control not detected (exit $rc); no trustworthy scan"; exit 2; }
echo 'real scanner controls passed (clean accepted, synthetic credential refused)'
