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
# Fails closed (exit 3) on an actions.lock schema it has not been tested on.
#
# The work is done by deonboard-workflow.sh, the one implementation, which
# the language-gate rollout also uses. Two copies drifted once: the schema
# guard and the case-insensitive prune landed here and not there.
set -euo pipefail

repo="${1:?usage: deonboard-estate-audit.sh <repo-dir>}"
exec "$(dirname "${BASH_SOURCE[0]}")/deonboard-workflow.sh" "$repo" .github/workflows/main-estate-audit.yml
