#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Verify the official app's same-commit result; never run a duplicate scanner.
# 0=verified success, 1=official failure, 2=no trustworthy completed verdict.
set -euo pipefail
repo=${SUBJECT_REPOSITORY:-${GITHUB_REPOSITORY:-}}
sha=${SUBJECT_SHA:-}
wait=${MAX_WAIT_SECONDS:-180}
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && $sha =~ ^[0-9a-f]{40}$ ]] \
    || { echo 'valid repository and exact subject SHA required' >&2; exit 2; }
[[ $wait =~ ^[0-9]+$ && ${#wait} -le 3 ]] && (( 10#$wait <= 300 )) \
    || { echo 'wait budget must be 0..300 seconds' >&2; exit 2; }
for tool in gh jq timeout; do
    command -v "$tool" >/dev/null || { echo "$tool required" >&2; exit 2; }
done
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
deadline=$((SECONDS+10#$wait))
while :; do
    # A bounded request even with many pages. Never silently retry anonymously
    # after a denied probe or interpret denied access as no findings.
    if ! timeout --kill-after=2s 20s gh api --paginate \
        "repos/$repo/commits/$sha/check-runs?filter=all&per_page=100" >"$tmp/pages.json"; then
        echo 'Cannot inspect SonarCloud check results; check API permission/connectivity' >&2
        exit 2
    fi
    if ! jq -se 'length > 0 and all(.[]; (.check_runs | type) == "array")' "$tmp/pages.json" >/dev/null; then
        echo 'Malformed check-run response; no verdict' >&2; exit 2
    fi
    # The official app ID and slug were observed from GitHub on vocarium#47.
    # Do not accept an Actions job or another app impersonating its check name.
    # GitHub's increasing check-run IDs identify the newest run; started_at may
    # be null for a newer queued run, or change when an older run finally starts.
    selected=$(jq -sc --arg sha "$sha" '
        [.[] | .check_runs[] |
         select(.head_sha == $sha and .name == "SonarCloud Code Analysis" and
                .app.id == 12526 and .app.slug == "sonarqubecloud")]
        | if length == 0 then null
          elif any(.[]; (.id | type) != "number") then error("invalid check identity")
          else max_by(.id) end
    ' "$tmp/pages.json") || exit 2
    if [[ $selected != null ]] && ! jq -e '.id | type == "number" and . > 0 and floor == .' <<< "$selected" >/dev/null; then
        echo 'Malformed official check-run identity; no verdict' >&2; exit 2
    fi
    status=$(jq -r '.status // "missing"' <<< "$selected")
    if [[ $status == completed ]]; then
        conclusion=$(jq -r '.conclusion' <<< "$selected")
        id=$(jq -r '.id' <<< "$selected")
        case $conclusion in
            success|failure)
                printf 'Official SonarCloud check %s reported %s for %s at %s\n' "$id" "$conclusion" "$repo" "$sha"
                if [[ -n ${GITHUB_OUTPUT:-} ]]; then
                    printf 'check-run-id=%s\nconclusion=%s\n' "$id" "$conclusion" >> "$GITHUB_OUTPUT" || exit 2
                fi
                [[ $conclusion == success ]] && exit 0
                exit 1 ;;
            *) echo "SonarCloud completed without a trustworthy verdict ($conclusion)" >&2; exit 2 ;;
        esac
    fi
    remaining=$((deadline-SECONDS))
    if (( remaining <= 0 )); then
        echo "No completed official same-commit SonarCloud result (status=$status); not a pass" >&2
        exit 2
    fi
    delay=15
    (( remaining >= delay )) || delay=$remaining
    sleep "$delay"
done
