#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Reject known runner-invalid lock representations. Not a complete lock verifier.
# 0=representation accepted, 1=invalid records, 2=inspection not performed.
#
# A ref may repeat its key's SHA only for a reusable-workflow edge: a key that a
# workflow beside the lock calls as a job-level reusable
# (`owner/repo/.github/workflows/x.yml@<sha>`), whose nested `uses:` is absent or
# a list. A `uses:` list alone does not qualify, because a composite action
# carries one too. This is the rule of standards#1290, of the squabbler's
# self_sha_lock_records, and of RefOk in src/Proven/Lock/Model.idr. A workflow
# that does not parse leaves the caller set unknown: NOT RUN, never a silent
# withdrawal of every exemption.
set -euo pipefail
lock=${1:-}
yq --version 2>/dev/null | grep -q mikefarah || { echo 'mikefarah yq v4 required' >&2; exit 2; }
[[ -f $lock ]] || { echo 'lockfile missing' >&2; exit 2; }
version=$(yq -r .version "$lock") || exit 2
case $version in v0.0.2|v0.0.3) ;; *) echo "untested lock schema: $version" >&2; exit 2 ;; esac
yq -e '.dependencies | tag == "!!map"' "$lock" >/dev/null || { echo 'dependencies must be a mapping' >&2; exit 2; }
records=$(yq -r '.dependencies | to_entries | .[] | [.key, (.value.ref | tag), (.value.commit | tag), .value.ref, .value.commit, (.value.uses | tag)] | @tsv' "$lock") || exit 2
[[ -n $records ]] || { echo 'no dependency records inspected; no assurance' >&2; exit 2; }

callers=
shopt -s nullglob
for wf in "$(dirname "$lock")"/*.yml "$(dirname "$lock")"/*.yaml; do
    [[ $wf -ef $lock ]] && continue
    calls=$(yq -r '(.jobs // {}) | .[] | select(tag == "!!map") | .uses // "" | select(tag == "!!str")' "$wf" 2>/dev/null) || {
        echo "$wf does not parse; the reusable caller set is unknown" >&2; exit 2; }
    while IFS= read -r use; do
        [[ $use =~ ^([^./@][^/@]*)/([^/@]+)/\.github/workflows/[^@]+@([0-9a-fA-F]{40})$ ]] || continue
        callers+="${BASH_REMATCH[1],,}/${BASH_REMATCH[2],,}@${BASH_REMATCH[3],,}"$'\n'
    done <<< "$calls"
done

failed=0 count=0 exempt=0
while IFS=$'\t' read -r key reftag committag ref commit usestag; do
    count=$((count+1))
    suffix=${key##*@}
    if [[ $reftag != "!!str" || -z $ref ]]; then
        printf 'INVALID %s: ref must name the reviewed branch/tag, not repeat a commit SHA\n' "$key"
        failed=1
    elif [[ $ref =~ ^[0-9a-fA-F]{40}$ ]]; then
        if [[ ${ref,,} == "${suffix,,}" && ($usestag == "!!null" || $usestag == "!!seq") ]] &&
           grep -qxF -- "$(tr 'A-Z' 'a-z' <<< "$key")" <<< "$callers"; then
            exempt=$((exempt+1))
            printf 'ok (reusable-workflow edge) %s: ref repeats the pin a job-level caller names\n' "$key"
        else
            printf 'INVALID %s: ref must name the reviewed branch/tag, not repeat a commit SHA\n' "$key"
            failed=1
        fi
    fi
    if [[ $committag != "!!str" || ! $commit =~ ^sha1-[0-9a-f]{40}$ ]]; then
        printf 'INVALID %s: missing or malformed resolved commit\n' "$key"
        failed=1
    fi
    if [[ $suffix =~ ^[0-9a-fA-F]{40}$ && $commit != "sha1-${suffix,,}" ]]; then
        printf 'INVALID %s: literal-SHA key disagrees with resolved commit\n' "$key"
        failed=1
    fi
done <<< "$records"
echo "inspected $count dependency records ($exempt reusable-workflow edges); representation failures=$failed"
exit "$failed"
