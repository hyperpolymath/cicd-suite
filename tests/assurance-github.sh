#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Synthetic transport controls through the actual source-built Idris executable.
# These are not real-consumer receipts and cannot satisfy GOVERNANCE by themselves.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
for tool in idris2 jq gh git sha256sum timeout; do
    command -v "$tool" >/dev/null 2>&1 || { echo "$tool missing; NOT RUN" >&2; exit 2; }
done
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export ASSURANCE_REAL_DATE
ASSURANCE_REAL_DATE=$(command -v date)
export ASSURANCE_FIXTURE_DIR=""
mkdir "$work/bin"
cat >"$work/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 10 && $1 == api && $2 == --hostname && $3 == github.com &&
   $4 == --method && $5 == GET ]] || exit 95
fixture=$ASSURANCE_FIXTURE_DIR
endpoint=${!#}
repo=$(jq -r '.repository.full_name' "$fixture/policy.json")
subject=$(jq -r '.subject_sha' "$fixture/policy.json")
tree=$(jq -r '.tree.sha' "$fixture/commit.json")
run=$(jq -r '.runs[0].id' "$fixture/policy.json")
printf '%s\n' "$endpoint" >>"$fixture/requests"
case "$endpoint" in
    "repos/$repo") key=repository ;;
    "repos/$repo/git/commits/$subject") key=commit ;;
    "repos/$repo/git/trees/$tree?recursive=1") key=tree ;;
    "repos/$repo/actions/runs?head_sha=$subject&per_page=100&page=1") key=runs ;;
    "repos/$repo/actions/runs/$run") key=run ;;
    "repos/$repo/actions/runs/$run/jobs?filter=latest&per_page=100&page=1") key=jobs ;;
    *) exit 96 ;;
esac
case "$key" in
    repository|runs|run)
        count=0
        if [[ -f "$fixture/count-$key" ]]; then read -r count <"$fixture/count-$key"; fi
        printf '%s\n' "$((count+1))" >"$fixture/count-$key"
        if [[ $count == 0 ]]; then file="$key-before"; else file="$key-after"; fi
        ;;
    *) file=$key ;;
esac
[[ ! -f "$fixture/fail-$file" ]] || exit 22
if [[ $file == repository-after && -f "$fixture/finish-clock" ]]; then
    cp "$fixture/finish-clock" "$fixture/clock"
fi
cat "$fixture/$file.json"
GH
cat >"$work/bin/date" <<'DATE'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# == 2 && $1 == -u && $2 == +%s && -n ${ASSURANCE_FIXTURE_DIR:-} ]]; then
    count=0
    if [[ -f "$ASSURANCE_FIXTURE_DIR/clock-calls" ]]; then
        read -r count <"$ASSURANCE_FIXTURE_DIR/clock-calls"
    fi
    count=$((count+1))
    printf '%s\n' "$count" >"$ASSURANCE_FIXTURE_DIR/clock-calls"
    # One start, nine request guards, then pre/post-kernel decision clocks.
    if [[ $count -ge 12 && -f "$ASSURANCE_FIXTURE_DIR/after-kernel-clock" ]]; then
        cp "$ASSURANCE_FIXTURE_DIR/after-kernel-clock" "$ASSURANCE_FIXTURE_DIR/clock"
    fi
    cat "$ASSURANCE_FIXTURE_DIR/clock"
else
    exec "$ASSURANCE_REAL_DATE" "$@"
fi
DATE
chmod +x "$work/bin/gh" "$work/bin/date"
export PATH="$work/bin:$PATH"
# shellcheck source=scripts/assurance-github.sh
source "$root/scripts/assurance-github.sh"
if ! assurance_build "$work/compiler"; then
    echo "real bridge compilation unavailable; NOT RUN" >&2
    exit 2
fi

native_controls=0
wire_control() {
    local label=$1 payload=$2 expected_exit=$3 expected_output=$4 mode=${5:-decide}
    local status=0 result
    printf '%s\n' "$payload" >"$work/native-input.json"
    result=$(timeout 20 "$ASSURANCE_BINARY" "$mode" "$work/native-input.json") || status=$?
    [[ $status == "$expected_exit" && $result == "$expected_output" ]] ||
        { echo "FAIL native $label (status=$status output=$result)" >&2; exit 1; }
    ((native_controls+=1))
}
wire_control valid '["PASSED"]' 0 PASSED
wire_control empty '[]' 1 BLOCKED
wire_control failed '["PASSED","FAILED"]' 1 BLOCKED
wire_control pending '["PASSED","PENDING"]' 1 BLOCKED
wire_control unknown '["PASSED","UNKNOWN"]' 1 BLOCKED
wire_control no-constructor-authority '["AdmissionVerified"]' 2 UNKNOWN
wire_control no-json-witness '[{"state":"PASSED","admission":"AdmissionVerified"}]' 2 UNKNOWN
wire_control malformed '["PASSED"' 2 UNKNOWN
wire_control multiple-documents '["PASSED"] ["PASSED"]' 2 UNKNOWN
wire_control oversized-wire "$(jq -cn '[range(65)|"PASSED"]')" 2 UNKNOWN
wire_control nested-positive '{"a":{"id":1},"b":{"id":2},"items":[{"id":3},{"id":4}]}' 0 VALID_JSON validate
wire_control nested-duplicate '{"a":[{"id":{},"id":1}]}' 2 UNKNOWN validate
wire_control distinct-object-fields '{"a":{"x":1},"a":{"y":2}}' 2 UNKNOWN validate
wire_control escaped-key '{"\u0069d":1}' 2 UNKNOWN validate
wire_control non-ascii-key '{"é":1}' 2 UNKNOWN validate

fixture_count=0
collector_controls=0
baseline() {
    ((fixture_count+=1))
    fixture="$work/fixture-$fixture_count"
    mkdir "$fixture"
    export ASSURANCE_FIXTURE_DIR=$fixture
    now=$("$ASSURANCE_REAL_DATE" -u +%s)
    printf '%s\n' "$now" >"$fixture/clock"
    : >"$fixture/requests"
    jq -cn --argjson now "$now" '{
      schema:"proven-cicd/github-execution/v1",category:"experimental",route:"direct-head",
      repository:{full_name:"hyperpolymath/proven-cicd",id:1446155688,owner_id:6759885},
      subject_sha:"1111111111111111111111111111111111111111",
      issued_at:(($now-120)|todateiso8601),expires_at:(($now+600)|todateiso8601),max_age_seconds:3600,
      runs:[{id:1001,attempt:1,workflow_id:2001,path:".github/workflows/fixture.yml",
             workflow_blob_sha:"2222222222222222222222222222222222222222",
             event:"push",head_branch:"main",
             jobs:[{name:"Required execution",steps:["Provision verifier","Execute required control"]}]}]
    }' >"$fixture/policy.json"
    jq -cn '{id:1446155688,full_name:"hyperpolymath/proven-cicd",owner:{id:6759885},private:false}' \
       >"$fixture/repository-before.json"
    cp "$fixture/repository-before.json" "$fixture/repository-after.json"
    jq -cn '{sha:"1111111111111111111111111111111111111111",
             tree:{sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}' >"$fixture/commit.json"
    jq -cn '{sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",truncated:false,tree:[
      {path:".github",mode:"040000",type:"tree",sha:"3333333333333333333333333333333333333333"},
      {path:".github/workflows",mode:"040000",type:"tree",sha:"4444444444444444444444444444444444444444"},
      {path:".github/workflows/fixture.yml",mode:"100644",type:"blob",sha:"2222222222222222222222222222222222222222"}
    ]}' >"$fixture/tree.json"
    jq -cn --argjson now "$now" --slurpfile repository "$fixture/repository-before.json" '{
      id:1001,run_attempt:1,workflow_id:2001,path:".github/workflows/fixture.yml",
      event:"push",head_branch:"main",head_sha:"1111111111111111111111111111111111111111",
      head_commit:{id:"1111111111111111111111111111111111111111"},run_number:1,
      repository:$repository[0],head_repository:$repository[0],referenced_workflows:[],
      created_at:(($now-40)|todateiso8601),run_started_at:(($now-30)|todateiso8601),
      updated_at:(($now-10)|todateiso8601),status:"completed",conclusion:"success"
    }' >"$fixture/run-before.json"
    cp "$fixture/run-before.json" "$fixture/run-after.json"
    jq -cn --slurpfile run "$fixture/run-before.json" '{total_count:1,workflow_runs:$run}' \
       >"$fixture/runs-before.json"
    cp "$fixture/runs-before.json" "$fixture/runs-after.json"
    jq -cn --argjson now "$now" '{total_count:1,jobs:[{
      id:3001,run_id:1001,run_attempt:1,head_branch:"main",
      head_sha:"1111111111111111111111111111111111111111",
      run_url:"https://api.github.com/repos/hyperpolymath/proven-cicd/actions/runs/1001",
      name:"Required execution",status:"completed",conclusion:"success",
      created_at:(($now-25)|todateiso8601),started_at:(($now-24)|todateiso8601),
      completed_at:(($now-20)|todateiso8601),
      steps:[
        {name:"Provision verifier",number:1,status:"completed",conclusion:"success",
         started_at:(($now-24)|todateiso8601),completed_at:(($now-22)|todateiso8601)},
        {name:"Execute required control",number:2,status:"completed",conclusion:"success",
         started_at:(($now-22)|todateiso8601),completed_at:(($now-20)|todateiso8601)}
      ]
    }]}' >"$fixture/jobs.json"
}
change() {
    local file=$1 filter=$2
    jq -c "$filter" "$fixture/$file.json" >"$fixture/changed.json"
    mv "$fixture/changed.json" "$fixture/$file.json"
}
change_run() {
    change run-before "$1"
    cp "$fixture/run-before.json" "$fixture/run-after.json"
    jq -cn --slurpfile run "$fixture/run-before.json" '{total_count:1,workflow_runs:$run}' \
       >"$fixture/runs-before.json"
    cp "$fixture/runs-before.json" "$fixture/runs-after.json"
}
raw_replace() {
    local file=$1 old=$2 replacement=$3 raw
    raw=$(<"$fixture/$file.json")
    [[ $raw == *"$old"* ]] || { echo "missing raw fixture preimage" >&2; exit 1; }
    printf '%s\n' "${raw/"$old"/"$replacement"}" >"$fixture/$file.json"
}
check_case() {
    local label=$1 expected=$2 expected_exit=$3 expected_reason=${4:-} expected_probe=${5:-}
    local digest status output="$fixture/result"
    digest=$(sha256sum "$fixture/policy.json")
    digest=${digest%% *}
    if [[ -f "$fixture/wrong-digest" ]]; then digest=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff; fi
    set +e
    assurance_collect "$fixture/policy.json" "$digest" "$output" >"$fixture/stdout" 2>"$fixture/stderr"
    status=$?
    set -e
    [[ $status == "$expected_exit" ]] ||
        { echo "FAIL collector $label exit=$status" >&2; cat "$fixture/stderr" >&2; exit 1; }
    jq -e --arg verdict "$expected" \
       '.verdict == $verdict and .kernel_verdict == (if $verdict=="PASSED" then "PASSED" else "BLOCKED" end)' \
       "$output/receipt.json" >/dev/null ||
        { echo "FAIL collector $label receipt" >&2; cat "$output/receipt.json" >&2; exit 1; }
    if [[ -n $expected_reason ]]; then
        jq -e --arg reason "$expected_reason" '.reason == $reason' "$output/receipt.json" >/dev/null ||
            { echo "FAIL collector $label reason" >&2; exit 1; }
    fi
    if [[ -n $expected_probe ]]; then
        jq -e --arg probe "$expected_probe" '.probe == $probe' "$output/receipt.json" >/dev/null ||
            { echo "FAIL collector $label rejected another probe" >&2; exit 1; }
    fi
    if [[ $expected == PASSED ]]; then
        jq -e --arg digest "$digest" --arg source "$ASSURANCE_SOURCE_SHA" \
           '.policy_sha256 == $digest and .source_commit == $source and
            (.observations|length)>0 and all(.observations[];.state=="PASSED")' "$output/receipt.json" >/dev/null
        cmp "$fixture/policy.json" "$output/policy.json"
        [[ $(wc -l <"$fixture/requests") == 9 ]]
    fi
    ((collector_controls+=1))
    printf 'ok: %s -> %s\n' "$label" "$expected"
}

baseline
check_case valid PASSED 0
# Same shape and mixed shape duplicates must fail BEFORE jq drops a field.
for prefix in '1446155688' '{}' '[]' '{"nested":1}' '[1]' 'null' 'false' '"wrong"'; do
    baseline
    raw_replace repository-before '"id":1446155688' "\"id\":$prefix,\"id\":1446155688"
    check_case duplicate-repository-id UNKNOWN 2 invalid_raw_response_json repository-before
done
for prefix in '"success"' '{}' '[]' '{"nested":1}'; do
    baseline
    raw_replace run-before '"conclusion":"success"' "\"conclusion\":$prefix,\"conclusion\":\"success\""
    check_case duplicate-run-conclusion UNKNOWN 2 invalid_raw_response_json run-0-before
done
baseline
raw_replace jobs '"number":1' '"number":{},"number":1'
check_case nested-job-duplicate UNKNOWN 2 invalid_raw_response_json jobs-0
baseline
raw_replace repository-before '"id":1446155688' '"id":1446155688,"\u0069d":1446155688'
check_case escaped-alias UNKNOWN 2 invalid_raw_response_json repository-before
baseline
printf '[]\n' >>"$fixture/run-before.json"
check_case trailing-document UNKNOWN 2 invalid_raw_response_json run-0-before
baseline
printf '{"id":' >"$fixture/repository-before.json"
check_case malformed-document UNKNOWN 2 invalid_raw_response_json repository-before
baseline
: >"$fixture/wrong-digest"
check_case wrong-policy-digest UNKNOWN 2 policy_digest_mismatch
baseline
change policy '.runs[0].event="pull_request"'
check_case unsupported-policy-event UNKNOWN 2 invalid_policy_schema
baseline
change policy '.runs=[]'
check_case empty-policy UNKNOWN 2 invalid_policy_schema
baseline
change policy '.runs += [.runs[0] | .id=1002 | .workflow_id=2002]'
check_case unsupported-multiple-workflows UNKNOWN 2 invalid_policy_schema
baseline
change repository-before '.id=1'
check_case wrong-repository UNKNOWN 2 repository_binding
baseline
change repository-after '.owner.id=1'
check_case changed-owner UNKNOWN 2 repository_binding
baseline
change commit '.sha="ffffffffffffffffffffffffffffffffffffffff"'
check_case wrong-commit UNKNOWN 2 subject_binding
baseline
change tree '.truncated=true'
check_case truncated-tree UNKNOWN 2 incomplete_tree
baseline
change tree '.tree[0].mode="120000" | .tree[0].type="blob"'
check_case symlink-parent UNKNOWN 2 workflow_source_binding
baseline
change tree '.tree[2].mode="160000" | .tree[2].type="commit"'
check_case gitlink-workflow UNKNOWN 2 workflow_source_binding
baseline
change tree '.tree[2].sha="ffffffffffffffffffffffffffffffffffffffff"'
check_case wrong-workflow-source UNKNOWN 2 workflow_source_binding
baseline
change_run '.head_sha="ffffffffffffffffffffffffffffffffffffffff"'
check_case wrong-head UNKNOWN 2 run_binding
baseline
change_run '.event="pull_request"'
check_case merge-context UNKNOWN 2 run_binding
baseline
change_run '.referenced_workflows=[{path:"other/repo/.github/workflows/reuse.yml@abc",sha:"abc"}]'
check_case reusable-context UNKNOWN 2 run_binding
baseline
change_run 'del(.referenced_workflows)'
check_case missing-provenance UNKNOWN 2 run_binding
baseline
change runs-before '.total_count=2'
check_case truncated-run-page UNKNOWN 2 incomplete_run_inventory
baseline
change runs-after '.workflow_runs += [.workflow_runs[0] | .id=1002 | .run_number=2] | .total_count=2'
check_case superseded-during-collection UNKNOWN 2 superseded_final_run
baseline
change runs-before '.workflow_runs[0].status="in_progress" | .workflow_runs[0].conclusion=null'
check_case initial-inventory-same-attempt-change UNKNOWN 2 initial_inventory_changed
baseline
change runs-after '.workflow_runs[0].status="in_progress" | .workflow_runs[0].conclusion=null'
check_case final-inventory-same-attempt-change UNKNOWN 2 final_inventory_changed
baseline
change run-after '.run_attempt=2'
check_case rerun-attempt UNKNOWN 2 run_binding
baseline
: >"$fixture/fail-run-after"
check_case revoked-run UNKNOWN 2 request_failed
baseline
change jobs '.jobs=[] | .total_count=0'
check_case missing-job UNKNOWN 2 missing_job
baseline
change jobs '.total_count=2'
check_case truncated-job-page UNKNOWN 2 invalid_jobs
baseline
change jobs '.jobs += [.jobs[0] | .id=3002] | .total_count=2'
check_case ambiguous-job-name UNKNOWN 2 invalid_jobs
baseline
change jobs '.jobs[0].steps |= .[0:1]'
check_case missing-detector UNKNOWN 2 step_contract_mismatch
baseline
change jobs '.jobs[0].steps |= reverse'
check_case wrong-step-order UNKNOWN 2 invalid_jobs
baseline
change jobs '.jobs[0].steps[1].conclusion="skipped"'
check_case skipped-detector UNKNOWN 2
baseline
change jobs '.jobs[0].steps[0].conclusion="failure" | .jobs[0].conclusion="failure"'
check_case provisioning-failure FAILED 1
baseline
change jobs '.jobs[0].steps[1].conclusion="failure"'
check_case masked-step-failure FAILED 1
baseline
change_run '.conclusion="failure"'
change jobs '.jobs[0].conclusion="failure" | .jobs[0].steps[1].conclusion="failure"'
check_case observed-job-failure FAILED 1
baseline
change_run '.conclusion="failure"'
check_case unexplained-run-failure UNKNOWN 2 unexplained_run_failure
baseline
change_run '.status="queued" | .conclusion=null | .run_started_at=null'
change jobs '.jobs=[] | .total_count=0'
check_case queued-run PENDING 2
baseline
change policy '.max_age_seconds=5'
check_case stale-completion UNKNOWN 2 stale_run
baseline
change policy '.expires_at=((.issued_at|fromdateiso8601)+125|todateiso8601)'
printf '%s\n' "$((now+6))" >"$fixture/finish-clock"
check_case expired-during-collection UNKNOWN 2 policy_expired
baseline
change policy '.expires_at=((.issued_at|fromdateiso8601)+125|todateiso8601)'
printf '%s\n' "$((now+6))" >"$fixture/after-kernel-clock"
check_case expired-after-kernel UNKNOWN 2 policy_expired
baseline
printf '%s\n' "$((now+301))" >"$fixture/finish-clock"
check_case collection-bound UNKNOWN 2 collection_expired
baseline
change jobs '.jobs[0].completed_at="2099-01-01T00:00:00Z"'
check_case future-job UNKNOWN 2 invalid_execution_times
baseline
change_run '.updated_at="2026-02-31T00:00:00Z"'
check_case invalid-calendar-time UNKNOWN 2 run_binding

# Positive aggregation: a second mandatory job and an explicit supported event.
baseline
change policy '.runs[0].jobs += [{name:"Second required execution",steps:["Provision verifier","Execute required control"]}]'
change jobs '.jobs += [.jobs[0] | .id=3002 | .name="Second required execution"] | .total_count=2'
check_case two-required-jobs PASSED 0
baseline
change policy '.runs[0].event="workflow_dispatch"'
change_run '.event="workflow_dispatch"'
check_case direct-dispatch PASSED 0

# The second admitted repository is still a SYNTHETIC shape control.
baseline
change policy '.repository={full_name:"hyperpolymath/echidna",id:1101572347,owner_id:6759885}'
change repository-before '.id=1101572347 | .full_name="hyperpolymath/echidna"'
cp "$fixture/repository-before.json" "$fixture/repository-after.json"
change_run '.repository.id=1101572347 | .repository.full_name="hyperpolymath/echidna" |
            .head_repository.id=1101572347 | .head_repository.full_name="hyperpolymath/echidna"'
change jobs '.jobs[0].run_url="https://api.github.com/repos/hyperpolymath/echidna/actions/runs/1001"'
check_case synthetic-echidna-contract PASSED 0

# A compiler/setup refusal is NOT a proof rejection or an executed observation.
mkdir "$work/no-compiler"
printf '#!/usr/bin/env bash\nexit 127\n' >"$work/no-compiler/idris2"
chmod +x "$work/no-compiler/idris2"
digest=$(sha256sum "$fixture/policy.json")
set +e
PATH="$work/no-compiler:$PATH" bash "$root/scripts/assurance-github.sh" \
    "$fixture/policy.json" "${digest%% *}" "$work/no-compiler-result" >"$work/missing-compiler.json"
status=$?
set -e
[[ $status == 2 ]]
jq -e '.verdict=="UNKNOWN" and .kernel_verdict=="NOT_RUN" and .reason=="source_or_compiler_unavailable"' \
   "$work/missing-compiler.json" >/dev/null

baseline
check_case final-positive PASSED 0
printf 'real Idris bridge controls: %s wire/raw JSON; %s collector; 1 compiler-absence\n' \
    "$native_controls" "$collector_controls"
