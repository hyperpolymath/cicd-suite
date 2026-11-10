#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Experimental, read-only bridge for a named finite execution policy.
# Usage: assurance-github.sh POLICY_JSON EXPECTED_POLICY_SHA256 NEW_OUTPUT_DIR
# No outside receipt or verdict executable is accepted by this CLI.
set -euo pipefail

ASSURANCE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ASSURANCE_IDRIS_SOURCE=27780073c8631826d846499840b3857d9b9a4fd5

assurance_setup_unknown() {
    printf '{"schema":"proven-cicd/github-execution-receipt/v1","category":"experimental","verdict":"UNKNOWN","kernel_verdict":"NOT_RUN","reason":"%s"}\n' "$1"
    return 2
}

# A fresh build from checked Git source, never an executable supplied by a caller.
# The hosted job provisions the pinned compiler. A version string is recorded,
# not misrepresented as a compiler attestation for arbitrary local callers.
assurance_build() {
    local directory=$1 path source expected hash
    for command in idris2 jq gh git sha256sum timeout cmp cp date wc; do
        command -v "$command" >/dev/null 2>&1 || return 2
    done
    ASSURANCE_SOURCE_SHA=$(git -C "$ASSURANCE_ROOT" rev-parse --verify HEAD) || return 2
    [[ $ASSURANCE_SOURCE_SHA =~ ^[0-9a-f]{40}$ ]] || return 2
    mkdir -p "$directory/src/Assurance" || return 2
    : >"$directory/source-manifest.txt" || return 2
    for path in assurance-github.ipkg src/Assurance/Verdict.idr \
                src/Assurance/GitHub.idr src/Assurance/GitHubMain.idr \
                scripts/assurance-github.sh scripts/assurance-github.jq; do
        source="$ASSURANCE_ROOT/$path"
        expected="$directory/expected-source"
        git -C "$ASSURANCE_ROOT" show "$ASSURANCE_SOURCE_SHA:$path" >"$expected" || return 2
        cmp -s "$source" "$expected" || return 2
        hash=$(sha256sum "$expected") || return 2
        printf '%s  %s\n' "${hash%% *}" "$path" >>"$directory/source-manifest.txt" || return 2
        # Stage the immutable bytes just compared, never a later worktree read.
        case "$path" in
            assurance-github.ipkg|src/Assurance/Verdict.idr|\
            src/Assurance/GitHub.idr|src/Assurance/GitHubMain.idr)
                cp "$expected" "$directory/$path" || return 2 ;;
            scripts/assurance-github.jq)
                cp "$expected" "$directory/assurance-github.jq" || return 2 ;;
            scripts/assurance-github.sh) : ;;
            *) return 2 ;;
        esac
    done
    hash=$(sha256sum "$directory/source-manifest.txt") || return 2
    ASSURANCE_SOURCE_BUNDLE_SHA=${hash%% *}
    ASSURANCE_COMPILER_VERSION=$(idris2 --version) || return 2
    if ! (cd "$directory" && timeout 180 idris2 --build assurance-github.ipkg) \
        >"$directory/compiler.log" 2>&1; then
        cat "$directory/compiler.log" >&2
        return 2
    fi
    ASSURANCE_BINARY="$directory/build/exec/assurance-github"
    ASSURANCE_JQ_DIR="$directory"
    [[ -x $ASSURANCE_BINARY ]] || return 2
}

# The fixture harness sources this function after one real source build, so
# every case uses the same compiled kernel/collector without recompiling it.
# The production CLI always calls assurance_build itself first.
assurance_collect() (
    set -euo pipefail
    local policy_file=$1 expected_digest=$2 output=$3
    local work finished=0 started now actual repository subject tree_sha index run_id probe=policy
    local kernel_exit kernel_result kernel_verdict verdict response_hash
    [[ $expected_digest =~ ^[0-9a-f]{64}$ ]] ||
        { assurance_setup_unknown invalid_policy_digest; exit 2; }
    mkdir "$output" || { assurance_setup_unknown output_not_new; exit 2; }
    work=$(mktemp -d) || { assurance_setup_unknown temporary_storage_unavailable; exit 2; }
    unknown() {
        local reason=$1 observed=NOT_RUN result status=0
        # Malformed acquisition still reaches the actual kernel as UNKNOWN
        # when compilation succeeded; missing tools are never called proof.
        if [[ -x ${ASSURANCE_BINARY:-} ]]; then
            printf '["UNKNOWN"]\n' >"$work/unknown-wire.json"
            result=$(timeout 20 "$ASSURANCE_BINARY" decide "$work/unknown-wire.json") || status=$?
            if [[ $status == 1 && $result == BLOCKED ]]; then
                observed=BLOCKED
            else
                reason=kernel_unavailable
            fi
        fi
        finished=1
        printf '{"schema":"proven-cicd/github-execution-receipt/v1","category":"experimental","verdict":"UNKNOWN","kernel_verdict":"%s","reason":"%s","probe":"%s","source_commit":"%s"}\n' \
            "$observed" "$reason" "$probe" "$ASSURANCE_SOURCE_SHA" >"$output/receipt.json"
        cat "$output/receipt.json"
        rm -rf "$work"
        exit 2
    }
    cleanup() {
        local status=$?
        if [[ $finished != 1 ]]; then
            # unexpected shell/JSON/tool failures cannot leave an apparent pass
            trap - EXIT
            unknown unexpected_error
        fi
        rm -rf "$work"
        return "$status"
    }
    trap cleanup EXIT
    cp "$policy_file" "$work/policy.json" || unknown policy_unreadable
    actual=$(sha256sum "$work/policy.json") || unknown policy_unreadable
    [[ ${actual%% *} == "$expected_digest" ]] || unknown policy_digest_mismatch
    local validation validation_exit=0
    validation=$(timeout 20 "$ASSURANCE_BINARY" validate "$work/policy.json") || validation_exit=$?
    [[ $validation_exit == 0 && $validation == VALID_JSON ]] || unknown invalid_raw_policy_json
    jq -e -L "$ASSURANCE_JQ_DIR" 'include "assurance-github"; valid_policy' \
       "$work/policy.json" >/dev/null || unknown invalid_policy_schema

    repository=$(jq -er '.repository.full_name' "$work/policy.json") || unknown invalid_policy_schema
    subject=$(jq -er '.subject_sha' "$work/policy.json") || unknown invalid_policy_schema
    started=$(date -u +%s) || unknown invalid_clock
    [[ $started =~ ^[0-9]+$ ]] || unknown invalid_clock
    : >"$work/responses.sha256" || unknown temporary_storage_unavailable

    request() {
        local name=$1 endpoint=$2 status=0 size checked check_status=0 stamp hash
        probe=$name
        stamp=$(date -u +%s) || unknown invalid_clock
        [[ $stamp =~ ^[0-9]+$ ]] || unknown invalid_clock
        (( stamp >= started && stamp - started <= 300 )) || unknown collection_expired
        timeout 60 gh api --hostname github.com --method GET \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' "$endpoint" \
            >"$work/$name.json" 2>"$work/$name.error" || status=$?
        [[ $status == 0 ]] || unknown request_failed
        size=$(wc -c <"$work/$name.json") || unknown response_size
        (( size > 0 && size <= 8388608 )) || unknown response_size
        checked=$(timeout 20 "$ASSURANCE_BINARY" validate "$work/$name.json") || check_status=$?
        [[ $check_status == 0 && $checked == VALID_JSON ]] || unknown invalid_raw_response_json
        # Idris checks raw field identity first; jq only sees admitted JSON.
        jq -e 'true' "$work/$name.json" >/dev/null || unknown invalid_response_json
        hash=$(sha256sum "$work/$name.json") || unknown response_digest_error
        printf '%s  %s.json\n' "${hash%% *}" "$name" >>"$work/responses.sha256" || unknown response_digest_error
    }

    request repository-before "repos/$repository"
    jq -e --slurpfile policy "$work/policy.json" -L "$ASSURANCE_JQ_DIR" \
       'include "assurance-github"; repository_matches($policy[0])' \
       "$work/repository-before.json" >/dev/null || unknown repository_binding
    request commit "repos/$repository/git/commits/$subject"
    jq -e --arg subject "$subject" -L "$ASSURANCE_JQ_DIR" \
       'include "assurance-github"; .sha == $subject and (.tree.sha | sha)' \
       "$work/commit.json" >/dev/null || unknown subject_binding
    tree_sha=$(jq -er '.tree.sha' "$work/commit.json") || unknown subject_binding
    request tree "repos/$repository/git/trees/$tree_sha?recursive=1"
    request runs-before "repos/$repository/actions/runs?head_sha=$subject&per_page=100&page=1"
    : >"$work/snapshots.jsonl" || unknown temporary_storage_unavailable
    local count
    count=$(jq -er '.runs | length' "$work/policy.json") || unknown invalid_policy_schema
    for ((index=0; index<count; index++)); do
        run_id=$(jq -er --argjson index "$index" '.runs[$index].id' "$work/policy.json") || unknown invalid_policy_schema
        request "run-$index-before" "repos/$repository/actions/runs/$run_id"
        request "jobs-$index" "repos/$repository/actions/runs/$run_id/jobs?filter=latest&per_page=100&page=1"
    done
    # Re-read each run/attempt after job collection. Re-runs, deletion and
    # changed terminal state cannot reuse an earlier successful snapshot.
    for ((index=0; index<count; index++)); do
        run_id=$(jq -er --argjson index "$index" '.runs[$index].id' "$work/policy.json") || unknown invalid_policy_schema
        request "run-$index-after" "repos/$repository/actions/runs/$run_id"
        jq -n --slurpfile initial "$work/run-$index-before.json" \
              --slurpfile final "$work/run-$index-after.json" \
              --slurpfile jobs "$work/jobs-$index.json" \
              '{initial:$initial[0],final:$final[0],jobs:$jobs[0]}' >>"$work/snapshots.jsonl" || unknown temporary_storage_unavailable
    done
    request runs-after "repos/$repository/actions/runs?head_sha=$subject&per_page=100&page=1"
    request repository-after "repos/$repository"
    # Decision time is taken AFTER the final GET, not before collection.
    now=$(date -u +%s) || unknown invalid_clock
    [[ $now =~ ^[0-9]+$ ]] || unknown invalid_clock
    jq -n --argjson started "$started" \
       --slurpfile before "$work/repository-before.json" \
       --slurpfile after "$work/repository-after.json" \
       --slurpfile commit "$work/commit.json" --slurpfile tree "$work/tree.json" \
       --slurpfile runs_before "$work/runs-before.json" --slurpfile runs_after "$work/runs-after.json" \
       --slurpfile snapshots "$work/snapshots.jsonl" \
       '{started_at:$started,repository_before:$before[0],repository_after:$after[0],
         commit:$commit[0],tree:$tree[0],runs_before:$runs_before[0],
         runs_after:$runs_after[0],runs:$snapshots}' >"$work/bundle.json" || unknown temporary_storage_unavailable
    qualify_at() {
        local decision=$1 destination=$2
        jq -n -L "$ASSURANCE_JQ_DIR" --slurpfile policy "$work/policy.json" \
           --slurpfile bundle "$work/bundle.json" --argjson now "$decision" \
           'include "assurance-github"; qualify($policy[0];$bundle[0];$now)' \
           >"$destination" 2>"$work/qualification.error" || {
            local diagnostic reason pattern='^jq: error \(at <unknown>\): ([a-z_]+)$'
            diagnostic=$(<"$work/qualification.error")
            if [[ $diagnostic =~ $pattern ]]; then
                reason=${BASH_REMATCH[1]}
                case "$reason" in
                    invalid_policy|collection_expired|policy_expired|repository_binding|subject_binding|\
                    incomplete_tree|incomplete_run_inventory|missing_run_snapshot|run_binding|run_changed|\
                    invalid_run_time|superseded_initial_run|superseded_final_run|workflow_source_binding|\
                    initial_inventory_changed|final_inventory_changed|\
                    invalid_jobs|unexpected_job|stale_run|missing_job|invalid_execution_times|\
                    unexplained_run_failure|step_contract_mismatch)
                        unknown "$reason" ;;
                    *) unknown qualification_tool_error ;;
                esac
            fi
            unknown qualification_tool_error
        }
    }
    qualify_at "$now" "$work/observations.json"
    jq -e --slurpfile policy "$work/policy.json" '
       type == "array" and length == ($policy[0].runs|map(.jobs|length)|add)
       and all(.[]; .state=="PASSED" or .state=="FAILED" or .state=="PENDING" or .state=="UNKNOWN")' \
       "$work/observations.json" >/dev/null || unknown invalid_kernel_wire
    jq '[.[].state]' "$work/observations.json" >"$work/wire.json" || unknown invalid_kernel_wire
    kernel_exit=0
    kernel_result=$(timeout 20 "$ASSURANCE_BINARY" decide "$work/wire.json") || kernel_exit=$?
    case "$kernel_exit:$kernel_result" in
        0:PASSED) kernel_verdict=PASSED; verdict=PASSED ;;
        1:BLOCKED)
            kernel_verdict=BLOCKED
            verdict=$(jq -er '
                if length == 0 or any(.[]; .state == "UNKNOWN") then "UNKNOWN"
                elif any(.[]; .state == "FAILED") then "FAILED"
                elif any(.[]; .state == "PENDING") then "PENDING"
                else "UNKNOWN" end' "$work/observations.json") || unknown invalid_kernel_wire
            ;;
        *) unknown kernel_unavailable ;;
    esac
    # The pure kernel has decided this exact observation list. Recheck expiry
    # after executable work and retain that result only if the list is unchanged.
    now=$(date -u +%s) || unknown invalid_clock
    [[ $now =~ ^[0-9]+$ ]] || unknown invalid_clock
    qualify_at "$now" "$work/final-observations.json"
    cmp -s "$work/observations.json" "$work/final-observations.json" || unknown evidence_changed
    response_hash=$(sha256sum "$work/responses.sha256") || unknown response_digest_error
    jq -n --arg verdict "$verdict" --arg kernel "$kernel_verdict" \
       --arg policy_digest "$expected_digest" --arg source "$ASSURANCE_SOURCE_SHA" \
       --arg source_digest "$ASSURANCE_SOURCE_BUNDLE_SHA" \
       --arg compiler_source "$ASSURANCE_IDRIS_SOURCE" --arg compiler_version "$ASSURANCE_COMPILER_VERSION" \
       --arg response_digest "${response_hash%% *}" --argjson decision "$now" --argjson started "$started" \
       --slurpfile policy "$work/policy.json" --slurpfile observations "$work/observations.json" \
       '{schema:"proven-cicd/github-execution-receipt/v1",category:"experimental",
         verdict:$verdict,kernel_verdict:$kernel,scope:"named-finite-execution-policy",
         repository:$policy[0].repository,subject_sha:$policy[0].subject_sha,
         policy_sha256:$policy_digest,source_commit:$source,source_bundle_sha256:$source_digest,
         compiler:{expected_source:$compiler_source,version:$compiler_version,
                   provenance:"requires-pinned-workflow-provisioning"},
         decision_at:$decision,collection_started_at:$started,
         responses_manifest_sha256:$response_digest,observations:$observations[0]}' >"$output/receipt.json" || unknown receipt_write_failed
    cp "$work/responses.sha256" "$output/responses.sha256" || unknown receipt_write_failed
    cp "$work/policy.json" "$output/policy.json" || unknown receipt_write_failed
    finished=1
    cat "$output/receipt.json" || unknown receipt_emit_failed
    case "$verdict" in
        PASSED) exit 0 ;;
        FAILED) exit 1 ;;
        PENDING|UNKNOWN) exit 2 ;;
        *) exit 2 ;;
    esac
)

assurance_main() (
    set -euo pipefail
    [[ $# == 3 ]] || { assurance_setup_unknown invalid_arguments; exit 2; }
    local build
    build=$(mktemp -d)
    trap 'rm -rf "$build"' EXIT
    if ! assurance_build "$build"; then
        assurance_setup_unknown source_or_compiler_unavailable
        exit 2
    fi
    assurance_collect "$@"
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    assurance_main "$@"
fi
