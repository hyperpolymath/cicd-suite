#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Production scanner callers must pin a commit already published on suite main.
# PR-only implementation pins can become unresolvable after squash/branch deletion.
set -euo pipefail
pin=${1:-}
[[ $pin =~ ^[0-9a-f]{40}$ ]] || { echo 'scanner pin must be a full SHA' >&2; exit 2; }
status=$(gh api "repos/hyperpolymath/cicd-suite/compare/$pin...main" --jq .status) \
    || { echo 'cannot verify published scanner ancestry' >&2; exit 2; }
case $status in
    ahead|identical) echo "scanner pin $pin is published on suite main" ;;
    *) echo "scanner pin $pin is not on suite main (comparison=$status)" >&2; exit 1 ;;
esac
