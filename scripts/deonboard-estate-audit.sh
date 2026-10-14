#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# deonboard-estate-audit.sh <repo-dir>
#
# De-onboard .github/workflows/main-estate-audit.yml from <repo-dir>'s
# actions.lock. The script deletes that workflow's `workflows:` entry, then
# prunes every `dependencies:` entry that no remaining workflow, and no
# remaining dependency, still reaches. The result is pure removals:
# gh-actions-lock's 4-space layout is kept, so the diff is reviewable line by
# line.
#
# Why: the estate audit is now a thin caller of cicd-suite's reusable
# workflow, pinned at a full SHA. Onboarded, such a caller startup-fails with
# zero jobs under sha_pinning_required. The header of
# .github/workflows/main-estate-audit.yml records the evidence.
#
# Idempotent: a lock that does not list the workflow is left untouched.
set -euo pipefail

repo="${1:?usage: deonboard-estate-audit.sh <repo-dir>}"
lock="$repo/.github/workflows/actions.lock"
wf=".github/workflows/main-estate-audit.yml"

if ! yq --version 2>/dev/null | grep -q mikefarah; then
  echo "deonboard-estate-audit.sh needs mikefarah yq v4 (https://github.com/mikefarah/yq)" >&2
  exit 2
fi
if [ ! -f "$lock" ]; then
  echo "$repo: no actions.lock; nothing to de-onboard"
  exit 0
fi
if ! w="$wf" yq -e '.workflows | has(strenv(w))' "$lock" >/dev/null 2>&1; then
  echo "$repo: $wf is not onboarded; nothing to do"
  exit 0
fi

w="$wf" yq -i -I4 'del(.workflows[strenv(w)])' "$lock"

pruned=()
while :; do
  used=$( { yq '.workflows[][]' "$lock"
            yq '.dependencies[] | select(has("uses")) | .uses[]' "$lock"
          } | sort -u )
  unused=$(yq '.dependencies | keys | .[]' "$lock" | grep -vxF -f <(printf '%s\n' "$used") || true)
  [ -n "$unused" ] || break
  while IFS= read -r k; do
    k="$k" yq -i -I4 'del(.dependencies[strenv(k)])' "$lock"
    pruned+=("$k")
  done <<< "$unused"
done

echo "$repo: de-onboarded $wf; pruned ${#pruned[@]} orphaned dependenc(ies):"
if [ "${#pruned[@]}" -gt 0 ]; then printf '  %s\n' "${pruned[@]}"; fi
