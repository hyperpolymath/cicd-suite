#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Example-based regression controls, not formally proven tests.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat >"$work/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CALLS"
if [[ $1 == pr ]]; then
    printf '%s\n' '{"number":1,"state":"OPEN","headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","baseRefName":"release/test","mergeStateStatus":"BLOCKED","statusCheckRollup":[]}'
elif [[ $* == *'/rules/branches/'* ]]; then
    if [[ ${DENIED:-0} == 1 ]]; then echo '403 rules denied' >&2; exit 1; fi
    echo '[]'
elif [[ $* == *'/protection/'* ]]; then
    if [[ ${PROTECTION_STATUS:-200} == 404 ]]; then
        printf 'HTTP/2.0 404 Not Found\r\n\r\n{"message":"Not Found"}\n'
        echo 'gh: Not Found (HTTP 404)' >&2; exit 1
    fi
    if [[ ${PROTECTION_STATUS:-200} == 403 ]]; then
        printf 'HTTP/2.0 403 Forbidden\r\n\r\n'
        echo 'gh: denied (HTTP 403)' >&2; exit 1
    fi
    if [[ ${PROTECTION_STATUS:-200} == error ]]; then
        echo 'network failed while fetching /404' >&2; exit 1
    fi
    printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n{"contexts":["scan / gitleaks"]}\n'
elif [[ $* == *'/actions/runs?'* ]]; then
    # Run 1 is a historical failure superseded by run 2. Run 3 has no jobs.
    # The second API page contains run 4, which must not disappear.
    echo '{"workflow_runs":[{"id":1,"workflow_id":10,"event":"pull_request","head_branch":"x","run_number":1,"status":"completed","conclusion":"failure"},{"id":2,"workflow_id":10,"event":"pull_request","head_branch":"x","run_number":2,"status":"completed","conclusion":"success"},{"id":3,"workflow_id":11,"event":"pull_request","head_branch":"x","run_number":1,"status":"completed","conclusion":"failure"}]} {"workflow_runs":[{"id":4,"workflow_id":12,"event":"push","head_branch":"x","run_number":1,"status":"completed","conclusion":"failure"}]}' | jq --arg status "${RUN_STATUS:-completed}" '.workflow_runs |= map(if .id==3 then .status=$status else . end)' 
elif [[ $* == *'/runs/3/jobs?'* ]]; then
    if [[ ${JOBS_DENIED:-0} == 1 ]]; then echo '403 jobs denied' >&2; exit 1; fi
    echo '{"jobs":[]}'
elif [[ $* == *'/runs/4/jobs?'* ]]; then
    echo '{"jobs":[{"id":99,"conclusion":"failure"}]}'
else
    echo "unexpected call: $*" >&2; exit 1
fi
MOCK
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" CALLS="$work/calls"
bash "$root/scripts/inspect-pr-ci.sh" owner/repo 1 >"$work/report.json"
jq -e '.classic_required_checks.contexts==["scan / gitleaks"] and .zero_job_failures==[3] and (.latest_head_runs|length)==3 and (.non_success_run_jobs|length)==2 and .pr.mergeStateStatus=="BLOCKED" and (.limitations|length)>0' "$work/report.json" >/dev/null
grep -q 'rules/branches/release%2Ftest' "$CALLS"
grep -q -- '--paginate' "$CALLS"
! grep -q '/runs/1/jobs' "$CALLS"
! grep -Eq 'merge|rerun|PATCH|POST|DELETE' "$CALLS"
echo 'ok: hidden zero-job failure, pagination, latest-run selection, branch encoding, read-only calls'
rc=0
DENIED=1 bash "$root/scripts/inspect-pr-ci.sh" owner/repo 1 >"$work/denied.json" || rc=$?
[[ $rc == 2 ]]
jq -e '.rules.probe_error|contains("403")' "$work/denied.json" >/dev/null
echo 'ok: denied rules probe remains unknown, not healthy'
PROTECTION_STATUS=404 bash "$root/scripts/inspect-pr-ci.sh" owner/repo 1 >"$work/absent.json"
jq -e '.classic_required_checks == null' "$work/absent.json" >/dev/null
echo 'ok: absent classic protection is not a failed probe'
for status in 403 error; do
    rc=0
    PROTECTION_STATUS=$status bash "$root/scripts/inspect-pr-ci.sh" owner/repo 1 >"$work/protection-error.json" || rc=$?
    [[ $rc == 2 ]]
    jq -e '.classic_required_checks.probe_error | length > 0' "$work/protection-error.json" >/dev/null
done
echo 'ok: denied and other failed protection probes remain errors'
rc=0
JOBS_DENIED=1 bash "$root/scripts/inspect-pr-ci.sh" owner/repo 1 >"$work/jobs-denied.json" || rc=$?
[[ $rc == 2 ]]
jq -e '.zero_job_failures==[] and (.non_success_run_jobs[]|select(.id==3)|.result.probe_error|contains("403"))' "$work/jobs-denied.json" >/dev/null
echo 'ok: failed jobs probe is not mistaken for zero jobs'
rc=0
bash "$root/scripts/inspect-pr-ci.sh" owner/repo invalid >"$work/invalid" 2>&1 || rc=$?
[[ $rc == 2 ]]
echo 'ok: invalid arguments refused'
rc=0
RUN_STATUS=queued bash "$root/scripts/inspect-pr-ci.sh" owner/repo 1 >"$work/queued.json" || rc=$?
[[ $rc == 0 ]]
jq -e '.zero_job_failures==[] and any(.latest_head_runs[]; .id==3 and .status=="queued")' "$work/queued.json" >/dev/null
echo 'ok: queued empty job population is not a startup failure'
