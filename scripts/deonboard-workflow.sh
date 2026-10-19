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
# Fails closed (exit 3) on an actions.lock schema it has not been tested on.
# This is the one implementation: deonboard-estate-audit.sh is its
# estate-audit entry point and delegates here, so a fix lands for every
# caller at once (tests/deonboard-estate-audit.sh,
# tests/deonboard-lock-schemas.sh).
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

# Lockfile schemas this script is tested against, one fixture each in
# tests/fixtures/actions-lock/ (tests/deonboard-lock-schemas.sh). An untested
# schema fails closed: add its fixture first, then its version here.
known_versions="v0.0.2 v0.0.3"
ver=$(yq '.version' "$lock")
case " $known_versions " in
  *" $ver "*) ;;
  *) echo "$repo: actions.lock schema '$ver' is untested by this script (tested: $known_versions); see tests/deonboard-lock-schemas.sh" >&2
     exit 3 ;;
esac

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
