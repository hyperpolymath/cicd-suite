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
exec "$(dirname "${BASH_SOURCE[0]}")/deonboard-workflow.sh" "${1:?usage: deonboard-estate-audit.sh <repo-dir>}" .github/workflows/main-estate-audit.yml
