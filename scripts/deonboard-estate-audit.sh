#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# deonboard-estate-audit.sh <repo-dir>
#
# De-onboard .github/workflows/main-estate-audit.yml from <repo-dir>'s
# actions.lock. Kept for the callers that already invoke it; the general
# form is scripts/deonboard-workflow.sh <repo-dir> <workflow-path>, which
# this delegates to.
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

# owner/repo@ref -> lower-case owner/repo, ref as written. GitHub owner and
# repository names are case-insensitive, and gh actions-lock writes the
# nested `uses:` of a dependency in lower case while keeping the record key's
# original case: a lock can hold the edge 'swatinem/rust-cache@<sha>' and
# the record 'Swatinem/rust-cache@<sha>' (measured on hyperpolymath/januskey,
# 2026-10-14, under its hyperpolymath/standards record). Compared byte for
# byte, that record looks orphaned, and pruning it leaves a dangling edge,
# which kills the run at startup (standards scripts/close-lock.sh). Refs keep
# their case: git refs are case-sensitive.
lower_repo() { awk '{ i = index($0, "@"); print tolower(substr($0, 1, i - 1)) substr($0, i) }'; }

pruned=()
while :; do
  used=$( { yq '.workflows[][]' "$lock"
            yq '.dependencies[] | select(has("uses")) | .uses[]' "$lock"
          } | lower_repo | sort -u )
  unused=$(yq '.dependencies | keys | .[]' "$lock" | while IFS= read -r k; do
             printf '%s\n' "$k" | lower_repo | grep -qxF -f <(printf '%s\n' "$used") || printf '%s\n' "$k"
           done)
  [ -n "$unused" ] || break
  while IFS= read -r k; do
    k="$k" yq -i -I4 'del(.dependencies[strenv(k)])' "$lock"
    pruned+=("$k")
  done <<< "$unused"
done

echo "$repo: de-onboarded $wf; pruned ${#pruned[@]} orphaned dependenc(ies):"
if [ "${#pruned[@]}" -gt 0 ]; then printf '  %s\n' "${pruned[@]}"; fi
