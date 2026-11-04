#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Candidate-only adapter around the pinned standards regen_lock function.
set -euo pipefail
repository=${SUBJECT_REPOSITORY:-}
revision=${SUBJECT_SHA:-}
subject=${SUBJECT_DIR:?}
authority=${AUTHORITY_DIR:?}
output=${RECOVERY_OUTPUT:?}
authority_sha=d3e4b485a2af90c92a8e18af0888cd19cb132cd9
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case "$repository" in
  hyperpolymath/hypatia|hyperpolymath/boj-server-cartridges|hyperpolymath/echidna|hyperpolymath/cicd-squabbler|hyperpolymath/panic-attack) ;;
  *) echo 'Recovery subject is outside the admitted repository scope'; exit 2 ;;
esac
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] \
  || { echo 'Recovery subject is outside the admitted repository/revision scope'; exit 2; }
[[ -n "${RUNNER_TEMP:-}" && "$output" == "$RUNNER_TEMP/"* ]] \
  || { echo 'Recovery output must be in the disposable runner directory'; exit 2; }
mkdir -p "$output"
status=failed
shim_dir=''
finish() {
  local rc=$?
  if [[ "$status" != candidate-created ]]; then
    rm -f -- "$output/candidate-actions.lock" "$output/candidate.patch" "$output/SHA256SUMS"
    jq -n --arg repo "$repository" --arg sha "$revision" --arg authority "$authority_sha" --argjson exit_code "$rc" \
      '{schema_version:1,status:"failed",repository:$repo,subject_sha:$sha,authority_sha:$authority,exit_code:$exit_code,
        limitation:"No verified candidate was produced; no remote repository or policy was changed."}' > "$output/receipt.json"
  fi
  [[ -z "$shim_dir" ]] || rm -rf -- "$shim_dir"
  exit "$rc"
}
trap finish EXIT

[[ $(git -C "$subject" rev-parse HEAD) == "$revision" ]] || { echo 'Subject SHA mismatch'; exit 2; }
[[ $(git -C "$authority" rev-parse HEAD) == "$authority_sha" ]] || { echo 'Authority SHA mismatch'; exit 2; }
producer_sha=$(git -C "$root" rev-parse HEAD)
[[ -z "${GITHUB_SHA:-}" || "$producer_sha" == "$GITHUB_SHA" ]] || { echo 'Recovery implementation SHA mismatch'; exit 2; }
[[ -z $(git -C "$root" status --porcelain --untracked-files=all) ]] || { echo 'Recovery implementation checkout is dirty'; exit 2; }
[[ -z $(git -C "$subject" status --porcelain --untracked-files=all) ]] || { echo 'Subject checkout is dirty'; exit 2; }
[[ -z $(git -C "$authority" status --porcelain --untracked-files=all) ]] || { echo 'Authority checkout is dirty'; exit 2; }
lock=.github/workflows/actions.lock
[[ -f "$subject/$lock" && ! -L "$subject/$lock" ]] || { echo 'Original lock is absent or a symlink'; exit 2; }
for tool in gh jq yq gawk; do command -v "$tool" >/dev/null || { echo "$tool unavailable; generation NOT RUN"; exit 2; }; done
tool_manifest="$root/config/actions-lock-recovery-tool.json"
expected_tool_sha=$(jq -er '.sha256 | select(test("^[0-9a-f]{64}$"))' "$tool_manifest")
tool_binary=${RECOVERY_ACTIONS_LOCK_BIN:-}
[[ "$tool_binary" == "$RUNNER_TEMP/"* && -f "$tool_binary" && ! -L "$tool_binary" && -x "$tool_binary" ]] \
  || { echo 'Verified recovery binary is absent'; exit 2; }
tool_sha=$(sha256sum "$tool_binary" | cut -d ' ' -f1)
[[ "$tool_sha" == "$expected_tool_sha" ]] || { echo 'Recovery binary changed after installation'; exit 2; }
[[ "${XDG_DATA_HOME:-}" == "$RUNNER_TEMP/"* &&
   $(readlink -f "$XDG_DATA_HOME/gh/extensions/gh-actions-lock/gh-actions-lock") == "$tool_binary" ]] \
  || { echo 'Recovery extension binding changed after installation'; exit 2; }
version=$(gh actions-lock --version)
[[ "$version" =~ (^|[[:space:]])v?0\.2\.0([[:space:]]|$) ]] || { echo 'Official tool is not the canonical v0.2.0'; exit 2; }
cp -- "$subject/$lock" "$output/original-actions.lock"
export RECOVERY_ORIGINAL_LOCK_SHA256
RECOVERY_ORIGINAL_LOCK_SHA256=$(sha256sum "$output/original-actions.lock" | cut -d ' ' -f1)
export RECOVERY_REAL_GH
RECOVERY_REAL_GH=$(command -v gh)
export RECOVERY_OUTPUT=$output
export REGEN_TOOLS="$authority/scripts"
shim_dir=$(mktemp -d "$RUNNER_TEMP/lock-recovery-tools.XXXXXX")
cp -- "$root/scripts/recover-unreadable-lock-gh.sh" "$shim_dir/gh-recovery"
chmod 700 "$shim_dir/gh-recovery"
export GH_BIN="$shim_dir/gh-recovery"

# Sourcing defines regen_lock; it does not call the authority's main/applier.
# regen_lock retains the original prior, restores every workflow byte, and
# executes relock-sha-keys -> complete-job-refs -> close-lock -> prune-stale ->
# update-actions-lock --verify-local -> check-lock-sync without policy copies.
source "$REGEN_TOOLS/regen-dependabot-locks.sh"
outcome=''
if ! outcome=$(regen_lock "$subject" 2> "$output/canonical-regeneration.log"); then
  cat "$output/canonical-regeneration.log" >&2
  echo 'Canonical regeneration did not complete'
  exit 1
fi
printf '%s\n' "$outcome" > "$output/canonical-outcome.txt"
if [[ "$outcome" != changed ]]; then
  cat "$output/canonical-regeneration.log" >&2
  echo "Canonical outcome '$outcome' produced no repair candidate"
  exit 1
fi
[[ $(git -C "$subject" rev-parse HEAD) == "$revision" ]] || exit 2
[[ $(git -C "$subject" status --porcelain --untracked-files=all) == " M $lock" ]] \
  || { echo 'Generation changed more than actions.lock'; exit 1; }
git -C "$subject" diff --quiet -- . ":(exclude)$lock" \
  || { echo 'An original source/workflow byte changed'; exit 1; }
cp -- "$subject/$lock" "$output/candidate-actions.lock"
git -C "$subject" diff --binary -- "$lock" > "$output/candidate.patch"
[[ -s "$output/candidate.patch" ]] || { echo 'Empty patch is not a repair'; exit 1; }
candidate_sha=$(sha256sum "$output/candidate-actions.lock" | cut -d ' ' -f1)
jq -n --arg repo "$repository" --arg sha "$revision" --arg authority "$authority_sha" \
  --arg producer "$producer_sha" --arg run "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-hyperpolymath/cicd-suite}/actions/runs/${GITHUB_RUN_ID:-unavailable}" \
  --arg tool "$version" --arg tool_sha256 "$tool_sha" --argjson tool_identity "$(cat "$tool_manifest")" \
  --arg original "$RECOVERY_ORIGINAL_LOCK_SHA256" --arg candidate "$candidate_sha" \
  '{schema_version:1,status:"candidate-created",repository:$repo,subject_sha:$sha,
    authority_repository:"metadatastician/standards",authority_sha:$authority,official_tool:$tool,
    official_tool_sha256:$tool_sha256,official_tool_identity:$tool_identity,
    producer_sha:$producer,workflow_run:$run,
    original_lock_sha256:$original,candidate_lock_sha256:$candidate,
    changed_paths:[".github/workflows/actions.lock"],original_workflow_bytes_preserved:true,
    canonical_checks:["update-actions-lock.sh --verify-local","check-lock-sync.sh"],
    remote_writeback:false,security_settings_changed:false,
    limitation:"Candidate only. Apply with an expected-head check and obtain real target startup/governance results before claiming repair."}' > "$output/receipt.json"
(cd "$output" && sha256sum original-actions.lock candidate-actions.lock candidate.patch receipt.json > SHA256SUMS)
status=candidate-created
echo "Candidate produced for $repository@$revision; canonical policy accepted the disposable lock. No writeback was performed."
