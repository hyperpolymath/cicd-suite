#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# proven-lock-gate.sh WORKSPACE STAMPED_WORKFLOW
#
# The consumer side of the proven lock gate. The stamped workflow
# (templates/proven-lock-gate.yml) fetches this repository at its pinned SHA,
# verifies the commit, and runs this script from that checkout. In order:
#
#   1. drift      the consumer's copy must match its stamp (scripts/proven-stamp.sh)
#   2. toolchain  gcc and gmp.h; gmp.h is installed with apt only if absent
#   3. build      scripts/build-proven-lock.sh, from the shipped C
#   4. self-test  known answers on bundled fixtures, including a planted
#                 defect, so that a binary that always says CONSISTENT is refused
#   5. verdict    extract the workspace's facts and judge them (--json)
#
# The last line printed is PROVEN_LOCK_CLASS=<class> for the squabbler:
#   consistent        exit 0
#   defect            exit 1: the lock is inconsistent (findings above)
#   drift             exit 1: the stamped copy was edited (REFER, never auto-fixed)
#   not_run:<why>     exit 2: no verdict. <why> is toolchain, build or selftest,
#                     or extract. The job fails: NOT RUN is never a pass.
# A report record (proven-cicd/run-report/v1) is appended to
# $RUNNER_TEMP/proven-lock-report.jsonl when RUNNER_TEMP is set.
set -euo pipefail

suite=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
workspace=${1:-} stamped=${2:-}
readonly artifact=proven-lock-gate
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

report() { # OUTCOME CLASS [FINDINGS_JSON]
  local outcome=$1 class=$2 findings=${3:-[]}
  if [[ -n ${RUNNER_TEMP:-} ]]; then
    jq -cn --arg outcome "$outcome" --arg class "$class" --argjson findings "$findings" \
      --arg repo "${GITHUB_REPOSITORY:-}" --arg sha "${GITHUB_SHA:-}" \
      --arg run "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}" \
      --arg attempt "${GITHUB_RUN_ATTEMPT:-}" --arg suite_sha "$(git -C "$suite" rev-parse HEAD 2>/dev/null || true)" \
      --arg version "$(head -n 1 "$workspace/$stamped" 2>/dev/null | sed -n 's/^# proven-cicd: [^@]*@\([^ ]*\) .*/\1/p')" \
      '{schema: "proven-cicd/run-report/v1", artifact: "proven-lock-gate", content_version: $version,
        suite_sha: $suite_sha, repo: $repo, head_sha: $sha, run_url: $run, attempt: $attempt,
        outcome: $outcome, class: $class, findings: $findings}' \
      >> "$RUNNER_TEMP/proven-lock-report.jsonl" || true
  fi
}
finish() { # EXIT CLASS OUTCOME [FINDINGS_JSON]
  local code=$1 class=$2 outcome=$3 findings=${4:-[]}
  report "$outcome" "$class" "$findings"
  echo "PROVEN_LOCK_CLASS=$class"
  exit "$code"
}

[[ -d $workspace && -n $stamped ]] || finish 2 not_run:usage not_run
command -v jq >/dev/null || finish 2 not_run:toolchain not_run

# 1. drift. A copy whose body no longer matches its stamp is not the proven
# content, so it is never judged as if it were.
rc=0; bash "$suite/scripts/proven-stamp.sh" check "$workspace/$stamped" || rc=$?
case $rc in
  0) ;;
  1) finish 1 drift drift ;;
  *) finish 2 not_run:stamp not_run ;;
esac

# 2. toolchain
yq --version 2>/dev/null | grep -q mikefarah || finish 2 not_run:toolchain not_run
command -v gcc >/dev/null || finish 2 not_run:toolchain not_run
if ! printf '#include <gmp.h>\n' | gcc -x c -fsyntax-only - 2>/dev/null; then
  echo "gmp.h absent on this image; installing libgmp-dev"
  installed=0
  for delay in 0 10; do
    sleep "$delay"
    if sudo -n apt-get install -y -q --no-install-recommends libgmp-dev >/dev/null 2>&1 ||
       { sudo -n apt-get update -q >/dev/null 2>&1 &&
         sudo -n apt-get install -y -q --no-install-recommends libgmp-dev >/dev/null 2>&1; }; then
      installed=1; break
    fi
  done
  [[ $installed == 1 ]] || finish 2 not_run:toolchain not_run
fi

# 3. build
build_args=("$tmp/verdict")
[[ -n ${PROVEN_IDRIS2_SOURCE_DIR:-} ]] && build_args+=(--runtime "$PROVEN_IDRIS2_SOURCE_DIR")
bash "$suite/scripts/build-proven-lock.sh" "${build_args[@]}" || finish 2 not_run:build not_run
verdict=$tmp/verdict

# 4. self-test: the fresh binary must give the known answers before its
# verdict on this workspace is trusted.
selftest() { # CASE WANT_FIRST_LINE
  local case=$1 want=$2 got
  rm -rf -- "$tmp/case"; cp -R "$suite/tests/fixtures/proven-lock/$case/repo" "$tmp/case"
  [[ -d $tmp/case/dot-github ]] && mv "$tmp/case/dot-github" "$tmp/case/.github"
  bash "$suite/scripts/extract-lock-facts.sh" "$tmp/case" > "$tmp/st.json" 2>/dev/null || return 1
  got=$("$verdict" "$tmp/st.json" 2>/dev/null | head -n 1) || true
  [[ $got == "$want" ]]
}
selftest ok-tag-keyed CONSISTENT &&
  selftest self-sha-leaf INCONSISTENT &&
  selftest composite-transitive-missing INCONSISTENT &&
  selftest missing-composite NOT_RUN || finish 2 not_run:selftest not_run

# 5. verdict
rc=0; bash "$suite/scripts/extract-lock-facts.sh" "$workspace" > "$tmp/facts.json" || rc=$?
[[ $rc == 0 ]] || finish 2 not_run:extract not_run
rc=0; "$verdict" --json "$tmp/facts.json" > "$tmp/verdict.jsonl" || rc=$?
cat "$tmp/verdict.jsonl"
findings=$(jq -sc '[.[] | select(has("reason"))]' "$tmp/verdict.jsonl" 2>/dev/null || echo '[]')
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  {
    echo "### Proven lock gate"
    jq -r '"- `\(.reason)` \(.record_key // "") \(.workflow_file // "")"' <<<"$(jq -c '.[]' <<<"$findings")" 2>/dev/null || true
    jq -sr 'last | "Verdict: **\(.verdict)**" + (if (.unjudged | length) > 0 then " (not judged: " + (.unjudged | join("; ")) + ")" else "" end)' "$tmp/verdict.jsonl" 2>/dev/null || true
  } >> "$GITHUB_STEP_SUMMARY"
fi
case $rc in
  0) finish 0 consistent pass "$findings" ;;
  1) finish 1 defect fail "$findings" ;;
  *) finish 2 not_run:verdict not_run "$findings" ;;
esac
