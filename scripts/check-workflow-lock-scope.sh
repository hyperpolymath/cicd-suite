#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Coverage for the declared lock boundary, not remote provenance verification.
# 0=checked, 1=scope/coverage defect, 2=inspection unavailable/unsupported.
set -euo pipefail
ROOT=${SCOPE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
ROOT=$(realpath -e "$ROOT")
command -v jq >/dev/null || exit 2
yq --version 2>/dev/null | grep -q 'mikefarah/yq' || { echo 'mikefarah yq v4 required' >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
scope=$ROOT/config/workflow-lock-scope.json
jq -e '.schema_version==1 and (.workflows|type=="array" and length>0) and
 ([.workflows[].path]|length)==([.workflows[].path]|unique|length) and
 all(.workflows[]; (.path|test("^\\.github/workflows/[a-zA-Z0-9_-]+\\.ya?ml$")) and
 (.mode=="managed" or .mode=="immutable") and (.reason|type=="string" and length>0))' "$scope" >/dev/null || exit 1
for path in "$ROOT"/.github/workflows/*.yml "$ROOT"/.github/workflows/*.yaml; do
    [[ ! -f $path ]] || printf '%s\n' "${path#"$ROOT/"}"
done | LC_ALL=C sort > "$tmp/actual"
jq -r '.workflows[].path' "$scope" | LC_ALL=C sort > "$tmp/scoped"
cmp -s "$tmp/actual" "$tmp/scoped" || { echo 'workflow inventory differs from explicit lock scope' >&2; exit 1; }
yq -o=json '.' "$ROOT/.github/workflows/actions.lock" > "$tmp/lock.json" || exit 2
jq -e '.version=="v0.0.2" or .version=="v0.0.3"' "$tmp/lock.json" >/dev/null || exit 2
jq -r '.workflows | keys[]' "$tmp/lock.json" | LC_ALL=C sort > "$tmp/locked"
jq -r '.workflows[]|select(.mode=="managed")|.path' "$scope" | LC_ALL=C sort > "$tmp/managed"
cmp -s "$tmp/locked" "$tmp/managed" || { echo 'managed workflow missing from lock map, or undeclared lock onboarding' >&2; exit 1; }
key_of() { local reference=$1; sed -E 's#^([^/]+/[^/@]+)(/[^@]*)?@(.*)$#\1@\3#' <<< "$reference"; }
while IFS= read -r row; do
    wf=$(jq -r .path <<< "$row"); mode=$(jq -r .mode <<< "$row")
    yq -o=json '.' "$ROOT/$wf" > "$tmp/workflow.json" || exit 2
    jq -er '.jobs|type=="object"' "$tmp/workflow.json" >/dev/null || exit 2
    # Only actual job/step uses, never strings inside run scripts or comments.
    jq -r '.jobs[] | (.uses // empty), (.steps[]?.uses // empty)' "$tmp/workflow.json" > "$tmp/queue"
    : > "$tmp/seen"
    while [[ -s $tmp/queue ]]; do
        IFS= read -r ref < "$tmp/queue"
        sed '1d' "$tmp/queue" > "$tmp/rest"; mv "$tmp/rest" "$tmp/queue"
        grep -Fxq "$ref" "$tmp/seen" && continue
        printf '%s\n' "$ref" >> "$tmp/seen"
        case $ref in
            '$/'*|./*)
                [[ $mode == managed && $ref == '$/'* ]] || { echo "$wf: unsupported unpinned local reference $ref" >&2; exit 1; }
                action=$(realpath -e "$ROOT/${ref#\$/}/action.yml") || exit 2
                [[ $action == "$ROOT/"* ]] || exit 1
                yq -o=json '.' "$action" > "$tmp/action.json" || exit 2
                jq -r '.runs.steps[]?.uses // empty' "$tmp/action.json" >> "$tmp/queue"
                ;;
            *)
                [[ $ref =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[^@[:space:]]+)?@[^@[:space:]]+$ ]] || { echo "$wf: unsupported uses: $ref" >&2; exit 2; }
                if [[ $mode == immutable ]]; then
                    [[ ${ref##*@} =~ ^[0-9a-f]{40}$ ]] || { echo "$wf: immutable workflow has a floating reference $ref" >&2; exit 1; }
                    continue
                fi
                # Job-level remote reusable calls are not covered by the CLI.
                # Require explicit immutable source instead of inventing a lock key.
                if [[ $ref == */.github/workflows/* ]]; then
                    [[ ${ref##*@} =~ ^[0-9a-f]{40}$ ]] || exit 1
                    continue
                fi
                key=$(key_of "$ref")
                jq -e --arg wf "$wf" --arg key "$key" '
                  (.workflows[$wf]|index($key)!=null) and (.dependencies|has($key))
                ' "$tmp/lock.json" >/dev/null || { echo "$wf: missing lock coverage for $key" >&2; exit 1; }
                jq -r --arg key "$key" '.dependencies[$key].uses[]? // empty' "$tmp/lock.json" >> "$tmp/queue"
                ;;
        esac
    done < /dev/null
    printf 'checked %s (%s)\n' "$wf" "$mode"
done < <(jq -c '.workflows[]' "$scope")
echo 'lock scope and managed coverage checked; remote source provenance/closure not certified'
