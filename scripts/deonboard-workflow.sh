#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# deonboard-workflow.sh <repo-dir> <workflow-path>
#
# De-onboard one workflow (default .github/workflows/main-estate-audit.yml)
# from <repo-dir>'s actions.lock: delete its `workflows:` entry, then prune
# every `dependencies:` entry that no remaining workflow, and no remaining
# dependency, still reaches. Pure removals; gh-actions-lock's 4-space layout
# is kept so the diff is reviewable line by line.
#
# Why: a thin caller of a cross-repository reusable workflow, pinned at a
# full SHA, startup-fails with zero jobs when it is ONBOARDED under
# sha_pinning_required (main-estate-audit.yml's header records the witnessed
# matrix). The estate-audit caller, the Rust CI caller and the Creusot,
# SPARK and miniKanren gate callers are all of that shape.
#
# Idempotent: a lock that does not list the workflow is left untouched.
# deonboard-estate-audit.sh is the original single-purpose form and now
# delegates here.
set -euo pipefail

repo="${1:?usage: deonboard-workflow.sh <repo-dir> [<workflow-path>]}"
wf="${2:-.github/workflows/main-estate-audit.yml}"
lock="$repo/.github/workflows/actions.lock"

case "$wf" in
  .github/workflows/*.yml|.github/workflows/*.yaml) ;;
  *) echo "deonboard-workflow.sh: workflow path must be .github/workflows/<name>.yml, got '$wf'" >&2; exit 64 ;;
esac

if ! yq --version 2>/dev/null | grep -q mikefarah; then
  echo "deonboard-workflow.sh needs mikefarah yq v4 (https://github.com/mikefarah/yq)" >&2
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
