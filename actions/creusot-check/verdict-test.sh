#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
# Tests of the reducer's attribution and acceptance boundary, not proof runs.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0
case_verdict() { # <label> <exit> <class> [overrides...]
  local label=$1 want=$2 class=$3 rc=0; shift 3
  : > "$work/output"
  env -i PATH="$PATH" GITHUB_OUTPUT="$work/output" \
    EXPECTED_SOURCE_REVISION=1111111111111111111111111111111111111111 \
    EXPECTED_SUITE_REVISION=2222222222222222222222222222222222222222 \
    SOURCE_REVISION=1111111111111111111111111111111111111111 \
    SUITE_REVISION=2222222222222222222222222222222222222222 \
    R_DETECT=success R_THEATRE=success OBLIGATIONS=true R_PROVE=success \
    PROOF_STEP_OUTCOME=success EXECUTION_STAGE=substantive EXECUTION_OUTCOME=passed \
    CONTROLS_PASSED=true PROOF_STARTED=true PROOF_COMPLETED=true \
    CRATES_EXPECTED=2 CRATES_ATTEMPTED=2 CRATES_COMPLETED=2 PROOF_EXIT_CODE=0 \
    "$@" bash --noprofile --norc -e -o pipefail "$here/verdict.sh" > "$work/log" 2>&1 || rc=$?
  if [[ "$rc" -ne "$want" ]] || ! grep -qx "execution_class=$class" "$work/output"; then
    printf 'FAIL: %s (exit %s, expected %s/%s)\n' "$label" "$rc" "$want" "$class" >&2
    cat "$work/log" "$work/output" >&2
    exit 1
  fi
  printf 'ok: %s\n' "$label"
  passed=$((passed + 1))
}

case_verdict 'complete current invocation' 0 Verified
case_verdict 'missing installer does not adjudicate contracts' 2 PrerequisiteMissing \
  R_PROVE=failure PROOF_STEP_OUTCOME=skipped SOURCE_REVISION= SUITE_REVISION=
grep -q 'no caller proof was performed' "$work/log"
case_verdict 'skipped required proof remains blocking' 2 PrerequisiteMissing \
  R_PROVE=skipped PROOF_STEP_OUTCOME=
case_verdict 'zero-step success is not a proof' 2 Unclassified PROOF_STEP_OUTCOME=skipped
case_verdict 'cancelled job is incomplete, not a failed contract' 2 Unclassified R_PROVE=cancelled
case_verdict 'discovery failed before proof' 2 PreflightFailed R_DETECT=failure
case_verdict 'theatre failure prevents caller proof' 2 PrerequisiteMissing R_THEATRE=failure
case_verdict 'missing scope is unavailable' 2 Unclassified OBLIGATIONS=
case_verdict 'no obligations is explicitly non-assurance' 0 NotApplicable OBLIGATIONS=false R_PROVE=skipped
if grep -qi 'verdict: GREEN\|execution: Verified' "$work/log"; then
  echo 'FAIL: inapplicability was presented as proof success' >&2
  exit 1
fi
case_verdict 'unexpected proof outside scope is refused' 2 Unclassified OBLIGATIONS=false
case_verdict 'a missing caller configuration is a prerequisite' 2 PrerequisiteMissing \
  R_PROVE=failure PROOF_STEP_OUTCOME=failure EXECUTION_STAGE=setup \
  EXECUTION_OUTCOME=unavailable PROOF_STARTED=false PROOF_COMPLETED=false PROOF_EXIT_CODE=2
case_verdict 'oracle failure is not a caller finding' 2 Unclassified \
  R_PROVE=failure PROOF_STEP_OUTCOME=failure EXECUTION_STAGE=harness \
  EXECUTION_OUTCOME=failed PROOF_STARTED=false PROOF_COMPLETED=false PROOF_EXIT_CODE=2
case_verdict 'actual failed command stays red without guessing why' 1 PolicyStepFailed \
  R_PROVE=failure PROOF_STEP_OUTCOME=failure EXECUTION_OUTCOME=failed PROOF_EXIT_CODE=1
case_verdict 'zero-work caller report cannot become a verified result' 2 Unclassified \
  R_PROVE=failure PROOF_STEP_OUTCOME=failure EXECUTION_OUTCOME=unavailable PROOF_EXIT_CODE=2

for field in SOURCE_REVISION SUITE_REVISION EXPECTED_SOURCE_REVISION EXPECTED_SUITE_REVISION; do
  case_verdict "absent $field" 2 Unclassified "$field="
  case_verdict "stale $field" 2 Unclassified "$field=3333333333333333333333333333333333333333"
done
for field in CONTROLS_PASSED PROOF_STARTED PROOF_COMPLETED; do
  case_verdict "missing $field" 2 Unclassified "$field="
  case_verdict "false $field" 2 Unclassified "$field=false"
done
for field in CRATES_EXPECTED CRATES_ATTEMPTED CRATES_COMPLETED; do
  for count in '' 0 -1 01 1000000000 invalid; do
    case_verdict "invalid $field '$count'" 2 Unclassified "$field=$count"
  done
done
case_verdict 'one omitted crate' 2 Unclassified CRATES_ATTEMPTED=1 CRATES_COMPLETED=1
case_verdict 'interrupted second crate' 2 Unclassified CRATES_COMPLETED=1
case_verdict 'success wrapper cannot overrule failed receipt' 2 Unclassified EXECUTION_OUTCOME=failed PROOF_EXIT_CODE=1
case_verdict 'failed job cannot overrule its step to green' 2 Unclassified R_PROVE=failure
case_verdict 'failed step cannot be laundered by job success' 2 Unclassified PROOF_STEP_OUTCOME=failure
case_verdict 'unknown stage' 2 Unclassified EXECUTION_STAGE=other
case_verdict 'unknown exit' 2 Unclassified PROOF_EXIT_CODE=garbled
printf 'PASS=%s FAIL=0 (execution attribution, not formal proof)\n' "$passed"
