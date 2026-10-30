#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Read-only evidence for humans and cicd-squabbler, not a merge authorisation.
# Usage: bash scripts/inspect-pr-ci.sh OWNER/REPO PR_NUMBER
set -euo pipefail
if [[ $# != 2 || ! $1 =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || ! $2 =~ ^[1-9][0-9]*$ ]]; then
    echo 'usage: inspect-pr-ci.sh OWNER/REPO PR_NUMBER' >&2
    exit 2
fi
for tool in gh jq; do
    command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 2; }
done
repo=$1 number=$2
# Fetch all pages for an API endpoint and write their JSON values as an array.
# Fail if the API request or JSON parsing fails.
# gh versions before --slurp still emit one JSON document per API page.
paginated() { local endpoint=$1; gh api --paginate "$endpoint" | jq -s .; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Errors are data, never an empty healthy population. Do not collect logs or
# artifacts: they can contain secrets and require additional network hosts.
# Save a probe's stdout and stderr under the given name in $work. On failure,
# replace stdout with a probe_error record; successful output rejected by jq -e
# returns 2. Errors writing the record can also reach the caller.
collect() {
    local name=$1
    shift
    if "$@" >"$work/$name.json" 2>"$work/$name.err"; then
        jq -e 'true' "$work/$name.json" >/dev/null || return 2
    else
        jq -n --rawfile error "$work/$name.err" '{probe_error:$error}' >"$work/$name.json"
    fi
}
# Inspect the HTTP status, not an error message that merely mentions 404.
classic_protection() {
    local response="$work/protection.http" rc=0
    gh api --include "$1" >"$response" || rc=$?
    if (( rc != 0 )); then
        if head -n 1 "$response" | grep -Eq '^HTTP/[0-9.]+ 404([[:space:]]|$)'; then
            echo null
            return 0
        fi
        return "$rc"
    fi
    sed '1,/^\r\{0,1\}$/d' "$response"
}
collect pr gh pr view "$number" --repo "$repo" --json number,url,state,baseRefName,headRefOid,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup
if jq -e 'has("probe_error")' "$work/pr.json" >/dev/null; then
    cat "$work/pr.json"
    exit 2
fi
head=$(jq -er '.headRefOid' "$work/pr.json")
base=$(jq -er '.baseRefName' "$work/pr.json")
encoded_base=$(jq -rn --arg value "$base" '$value|@uri')
collect rules paginated "repos/$repo/rules/branches/$encoded_base"
collect protection classic_protection "repos/$repo/branches/$encoded_base/protection/required_status_checks"
# Both PR and push workflows count; a zero-job run never appears in rollup.
# Paginate rather than trusting gh run list's default limit of twenty.
collect runs paginated "repos/$repo/actions/runs?head_sha=$head&per_page=100"
if jq -e 'type=="array"' "$work/runs.json" >/dev/null; then
    jq '[.[] | .workflow_runs[]] | group_by(.workflow_id,.event,.head_branch) | map(max_by(.run_number,.run_attempt))' \
        "$work/runs.json" >"$work/latest.json"
    while IFS= read -r id; do
        collect "jobs-$id" paginated "repos/$repo/actions/runs/$id/jobs?per_page=100"
        jq -n --argjson id "$id" --slurpfile pages "$work/jobs-$id.json" \
            '{id:$id, result:$pages[0]}' >>"$work/jobs.jsonl"
    done < <(jq -r '.[] | select(.status!="completed" or .conclusion!="success") | .id' "$work/latest.json")
else
    cp "$work/runs.json" "$work/latest.json"
fi
: >>"$work/jobs.jsonl"
jq -n --arg repo "$repo" --arg observed_at "$(date -u +%FT%TZ)" \
    --slurpfile pr "$work/pr.json" --slurpfile rules "$work/rules.json" \
    --slurpfile protection "$work/protection.json" --slurpfile runs "$work/latest.json" \
    --slurpfile jobs "$work/jobs.jsonl" '
    {schema_version:1, observed_at:$observed_at, repository:$repo,
     pr:$pr[0], rules:$rules[0], classic_required_checks:$protection[0],
     latest_head_runs:$runs[0], non_success_run_jobs:$jobs,
     zero_job_failures:[$jobs[] | . as $job |
       select(any($runs[0][]?; .id==$job.id and .status=="completed" and .conclusion=="failure")) |
       select(.result|type=="array") |
       select(([.result[] | .jobs[]]|length)==0) | .id],
     limitations:["Evidence only; never permission to merge or bypass a required context.",
       "Runs queried for PR head SHA only; synthetic merge/merge-group runs are not covered.",
       "PR rollup can be truncated by GitHub; rules and classic protection probes may be denied.",
       "Zero jobs establish non-execution, not its cause. Use squabble zero-job/chains/fight.",
       "Snapshot is not atomic; re-fetch after each head, policy or upstream change."]}'
# A report with denied probes is useful, but must not exit as a clean inspection.
if grep -q '"probe_error"' "$work/"*.json; then exit 2; fi
