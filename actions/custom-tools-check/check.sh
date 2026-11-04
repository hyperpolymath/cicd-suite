#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# custom-tools-check — panic-attack & pons gate.
#
# Contract (the estate's exit-code convention, cf. rust-ci/creusot/spark/
# kanren check.sh):
#   0  both tools completed with strict coverage; Pons below warn threshold
#   1  a tool ran and reported a defect (non-zero exit of its own)
#   2  INCOMPLETE CHECK — missing tool, incomplete coverage or execution failure
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

deadline="${CUSTOM_TOOLS_TIMEOUT_SECONDS:-180}"
if [[ ! "$deadline" =~ ^[1-9][0-9]{0,3}$ ]] || (( deadline > 3600 )); then
  emit_status not_run
  echo "::error::CUSTOM_TOOLS_TIMEOUT_SECONDS must be 1..3600" >&2
  exit 2
fi

missing=()
command -v timeout >/dev/null 2>&1 || missing+=(timeout)
command -v pons >/dev/null 2>&1         || missing+=(pons)
command -v panic-attack >/dev/null 2>&1 || missing+=(panic-attack)

if [ "${#missing[@]}" -gt 0 ]; then
  emit_status not_run
  echo "::error::custom-tools-check: ${missing[*]} not on PATH — NO CHECK WAS PERFORMED (status=not_run). Install the tool(s) before this step, or do not call this gate; a scan that never ran is not a pass." >&2
  exit 2
fi

# Coverage failures and tool execution failures must not become green.
# Run both tools even if the first refuses, preserving independent evidence.
failed=0
incomplete=0
# run_scan <command> [args...] — run a scanner with the deadline in seconds
# and a five-second kill grace. Record exits 2 and 124–255 in incomplete,
# and exits 1 and 3–123 in failed; exit 0 leaves both flags unchanged.
# Non-zero command statuses are converted to these shared flags.
run_scan() {
  local rc=0 scanner=$1
  echo "Running: $*"
  timeout --kill-after=5 "${deadline}s" "$@" || rc=$?
  case "$rc" in
    0) ;;
    1) failed=1 ;;
    2|12[4-9]|1[3-9][0-9]|2[0-5][0-9])
      incomplete=1
      echo "::error::custom-tools-check: $scanner incomplete or unavailable (exit $rc)." ;;
    *) failed=1
       echo "::error::custom-tools-check: $scanner failed (exit $rc)." ;;
  esac
}
run_scan pons scan . --fail-on-skips --fail-on warn
run_scan panic-attack assail . --fail-on-incomplete

if [ "$incomplete" -eq 1 ]; then
  emit_status not_run
  echo "::error::custom-tools-check: complete checks were not performed; inspect both outputs."
  exit 2
fi
if [ "$failed" -eq 1 ]; then
  emit_status failed
  exit 1
fi
emit_status passed
echo "Both scanner commands completed with strict coverage. Pons gates warn/error findings; panic-attack assail findings remain report-only."
