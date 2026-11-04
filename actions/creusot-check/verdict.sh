#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
# Reduce observations of this workflow invocation. These outputs are local
# transport, not authenticated external evidence or a proof certificate.
set -euo pipefail

finish() { # <exit> <execution class> <explanation>
  local rc=$1 class=$2 explanation=$3 level=error
  [[ "$rc" -ne 0 ]] || level=notice
  printf '::%s::Creusot execution: %s — %s\n' "$level" "$class" "$explanation"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'execution_class=%s\n' "$class" >> "$GITHUB_OUTPUT"
  fi
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '### Creusot execution\n\n**%s**: %s\n' "$class" "$explanation" >> "$GITHUB_STEP_SUMMARY"
  fi
  exit "$rc"
}

# Failed prerequisite phases still block the existing required context. They
# do not adjudicate a proof of the caller's code that never ran.
[[ "${R_DETECT:-}" = success ]] || finish 2 PreflightFailed \
  'obligation discovery did not complete; no proof verdict is available.'
[[ "${R_THEATRE:-}" = success ]] || finish 2 PrerequisiteMissing \
  'the contract/claim gate did not pass; no caller proof was performed. Read that gate for its own finding.'

case "${OBLIGATIONS:-}" in
  false)
    if [[ "${R_PROVE:-}" = skipped ]]; then
      finish 0 NotApplicable 'no Creusot obligations were detected; no proof was performed and no proof success is claimed.'
    fi
    finish 2 Unclassified 'proof-job execution conflicts with the detected obligation scope.'
    ;;
  true) ;;
  *) finish 2 Unclassified 'the obligation scope is missing or invalid.' ;;
esac

if [[ "${R_PROVE:-}" = cancelled ]]; then
  finish 2 Unclassified 'the proof job was cancelled; completed caller proof evidence is unavailable.'
fi

case "${PROOF_STEP_OUTCOME:-}" in
  ''|skipped)
    if [[ "${R_PROVE:-}" = failure ]] || [[ "${R_PROVE:-}" = skipped ]]; then
      finish 2 PrerequisiteMissing 'no caller proof was performed: the proof step did not run. Inspect the failed installation/setup prerequisite.'
    fi
    finish 2 Unclassified 'a job result without an executed proof step cannot support a proof verdict.'
    ;;
  failure|success) ;;
  *) finish 2 Unclassified 'the proof step has no completed outcome.' ;;
esac

# Bind the receipt to the tree actually checked out, not merely the PR head.
# pull_request normally checks the synthetic merge revision (GITHUB_SHA).
[[ "${EXPECTED_SOURCE_REVISION:-}" =~ ^[0-9a-f]{40}$ ]] && \
[[ "${EXPECTED_SUITE_REVISION:-}" =~ ^[0-9a-f]{40}$ ]] && \
[[ "${SOURCE_REVISION:-}" = "$EXPECTED_SOURCE_REVISION" ]] && \
[[ "${SUITE_REVISION:-}" = "$EXPECTED_SUITE_REVISION" ]] || \
  finish 2 Unclassified 'the execution receipt is absent or belongs to a different source/gate revision.'

case "${EXECUTION_STAGE:-}:${EXECUTION_OUTCOME:-}:${PROOF_STARTED:-}" in
  setup:unavailable:false)
    finish 2 PrerequisiteMissing 'a declared tool, configuration or target prerequisite was unavailable; no caller proof was performed.'
    ;;
  harness:failed:false)
    finish 2 Unclassified 'the prover controls did not establish a usable oracle; no caller proof was performed. This is a harness failure, not a caller finding.'
    ;;
  *)
    # Other combinations must satisfy every substantive-execution guard below.
    ;;
esac

[[ "${EXECUTION_STAGE:-}" = substantive ]] && \
[[ "${CONTROLS_PASSED:-}" = true ]] && \
[[ "${PROOF_STARTED:-}" = true ]] && \
[[ "${PROOF_COMPLETED:-}" = true ]] || \
  finish 2 Unclassified 'there is no completed caller execution after successful prover controls.'

# These counters come from the invocation, not from a source-text contract
# count. Bound the decimal representation before any shell arithmetic.
for count in "${CRATES_EXPECTED:-}" "${CRATES_ATTEMPTED:-}" "${CRATES_COMPLETED:-}"; do
  [[ "$count" =~ ^[1-9][0-9]{0,8}$ ]] || \
    finish 2 Unclassified 'a nonempty, well-formed crate execution count is required.'
done
[[ "$CRATES_EXPECTED" = "$CRATES_ATTEMPTED" ]] && \
[[ "$CRATES_EXPECTED" = "$CRATES_COMPLETED" ]] || \
  finish 2 Unclassified 'the caller crate execution is incomplete; no complete proof verdict is available.'

if [[ "${EXECUTION_OUTCOME:-}" = failed ]] && [[ "${PROOF_EXIT_CODE:-}" = 1 ]] && \
   [[ "$PROOF_STEP_OUTCOME" = failure ]] && [[ "${R_PROVE:-}" = failure ]]; then
  finish 1 PolicyStepFailed 'the caller commands ran and at least one returned nonzero. Inspect the producer report; the exit alone does not identify a failed contract.'
fi

if [[ "${EXECUTION_OUTCOME:-}" = passed ]] && [[ "${PROOF_EXIT_CODE:-}" = 0 ]] && \
   [[ "$PROOF_STEP_OUTCOME" = success ]] && [[ "${R_PROVE:-}" = success ]]; then
  finish 0 Verified 'both prover controls and every selected caller command completed successfully on this revision. This is scoped execution evidence, not a repository-wide proof.'
fi

finish 2 Unclassified 'step, job and execution-receipt outcomes disagree; no proof verdict is available.'
