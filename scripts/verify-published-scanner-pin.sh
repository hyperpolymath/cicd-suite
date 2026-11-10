#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Production scanner callers must pin a commit already published on suite main.
# PR-only implementation pins can become unresolvable after squash/branch deletion.
set -euo pipefail
pin=${1:-}
repository=${2-hyperpolymath/cicd-suite}
[[ $pin =~ ^[0-9a-f]{40}$ ]] || { echo 'scanner pin must be a full SHA' >&2; exit 2; }
case "$repository" in
    hyperpolymath/cicd-suite|hyperpolymath/proven-cicd|hyperpolymath/proven-cicd-and-workflows) ;;
    *) echo 'scanner source repository is not admitted' >&2; exit 2 ;;
esac
status=$(gh api "repos/$repository/compare/$pin...main" --jq .status) \
    || { echo 'cannot verify published scanner ancestry' >&2; exit 2; }
case $status in
    ahead|identical) echo "scanner pin $repository@$pin is published on its main" ;;
    behind|diverged) echo "scanner pin $repository@$pin is not on its main (comparison=$status)" >&2; exit 1 ;;
    *) echo 'scanner ancestry result is unavailable or unknown' >&2; exit 2 ;;
esac
