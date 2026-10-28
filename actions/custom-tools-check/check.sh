#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# custom-tools-check — panic-attack & pons gate.
#
# Contract (the estate's exit-code convention, cf. rust-ci/creusot/spark/
# kanren check.sh):
#   0  both tools were on PATH, both ran, and both exited 0
#   1  a tool ran and reported a defect (non-zero exit of its own)
#   2  NO CHECK WAS PERFORMED — a required tool is not on PATH
#      (status=not_run). Exit 2 is never a pass.
#
# Why this exists: the previous inline version echoed "assuming it needs
# to run via standard caller" for each absent tool and then printed
# "Custom tools validation passed." Neither binary is on PATH on a
# normal GitHub runner, so every consumer of main-estate-audit was
# certifying scans that never ran. Absence is now a result, not a pass.
# Callers that want this gate must install panic-attack and pons first;
# the estate audit itself no longer runs it (panic-attack/pons evidence
# comes from the standards Hypatia lane's envelopes).

set -uo pipefail

emit_status() { # <status>
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "status=$1" >> "$GITHUB_OUTPUT"
  echo "custom-tools-check status=$1"
}

dir="${CUSTOM_TOOLS_WORKDIR:-.}"
cd "$dir" || { emit_status not_run; echo "::error::custom-tools-check: cannot enter $dir — NO CHECK WAS PERFORMED (status=not_run)." >&2; exit 2; }

missing=()
command -v pons >/dev/null 2>&1         || missing+=(pons)
command -v panic-attack >/dev/null 2>&1 || missing+=(panic-attack)

if [ "${#missing[@]}" -gt 0 ]; then
  emit_status not_run
  echo "::error::custom-tools-check: ${missing[*]} not on PATH — NO CHECK WAS PERFORMED (status=not_run). Install the tool(s) before this step, or do not call this gate; a scan that never ran is not a pass." >&2
  exit 2
fi

fail=0
echo "Running: pons verify ."
pons verify . || { rc=$?; echo "::error::custom-tools-check: 'pons verify .' exited $rc."; fail=1; }
echo "Running: panic-attack scan ."
panic-attack scan . || { rc=$?; echo "::error::custom-tools-check: 'panic-attack scan .' exited $rc."; fail=1; }

if [ "$fail" -eq 1 ]; then
  emit_status failed
  exit 1
fi

emit_status passed
echo "Custom tools validation passed (pons and panic-attack both ran and exited 0)."
