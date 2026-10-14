#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
#
# Install the estate audit into every local estate clone as a THIN CALLER of
# this repository's reusable workflow, plus the weekly bot that keeps its pin
# current. This script used to copy the whole 26-step workflow into each repo.
# Every copy then froze at whatever cicd-suite commit its actions.lock held,
# so fixes made here never reached a consumer.
#
# Per repository, the script:
#   1. writes .github/workflows/main-estate-audit.yml from
#      templates/estate-audit-caller.yml, pinned at this clone's origin/main;
#   2. writes .github/workflows/track-estate-audit.yml (weekly pin bump);
#   3. de-onboards the caller from actions.lock
#      (scripts/deonboard-estate-audit.sh).
# Files are written, not committed: review and commit them per repository.
set -euo pipefail

suite="${CICD_SUITE:-/home/hyperpolymath/developer/hyper-repos/cicd-suite}"
repos="${HYPER_REPOS:-/home/hyperpolymath/developer/hyper-repos}"

git -C "$suite" fetch --quiet origin main
sha=$(git -C "$suite" rev-parse origin/main)
# A caller pinned at a commit whose audit is not a reusable workflow cannot
# start, so refuse before writing anything.
if ! git -C "$suite" show "$sha:.github/workflows/main-estate-audit.yml" 2>/dev/null \
     | grep -qE '^[[:space:]]+workflow_call:'; then
  echo "cicd-suite ${sha:0:7}: main-estate-audit.yml has no workflow_call trigger; refusing to roll out." >&2
  exit 1
fi
echo "Installing the estate-audit caller (cicd-suite ${sha:0:7}) into $repos/* ..."

for repo in "$repos"/*; do
  [ -d "$repo/.git" ] || continue
  [ "$(basename "$repo")" != "cicd-suite" ] || continue
  echo "== $repo"
  mkdir -p "$repo/.github/workflows"
  sed "s/__CICD_SUITE_SHA__/$sha/" "$suite/templates/estate-audit-caller.yml" \
    > "$repo/.github/workflows/main-estate-audit.yml"
  cp "$suite/templates/track-estate-audit.yml" "$repo/.github/workflows/track-estate-audit.yml"
  "$suite/scripts/deonboard-estate-audit.sh" "$repo"
done

echo "Rollout complete. Commit per repository after review."
