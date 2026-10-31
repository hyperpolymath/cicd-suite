#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Reject known runner-invalid lock representations. Not a complete lock verifier.
# 0=representation accepted, 1=invalid records, 2=inspection not performed.
set -euo pipefail
lock=${1:-}
yq --version 2>/dev/null | grep -q mikefarah || { echo 'mikefarah yq v4 required' >&2; exit 2; }
[[ -f $lock ]] || { echo 'lockfile missing' >&2; exit 2; }
version=$(yq -r .version "$lock") || exit 2
case $version in v0.0.2|v0.0.3) ;; *) echo "untested lock schema: $version" >&2; exit 2 ;; esac
yq -e '.dependencies | tag == "!!map"' "$lock" >/dev/null || { echo 'dependencies must be a mapping' >&2; exit 2; }
records=$(yq -r '.dependencies | to_entries | .[] | [.key, (.value.ref | tag), (.value.commit | tag), .value.ref, .value.commit] | @tsv' "$lock") || exit 2
[[ -n $records ]] || { echo 'no dependency records inspected; no assurance' >&2; exit 2; }
failed=0 count=0
while IFS=$'\t' read -r key reftag committag ref commit; do
    count=$((count+1))
    if [[ $reftag != "!!str" || -z $ref || $ref =~ ^[0-9a-fA-F]{40}$ ]]; then
        printf 'INVALID %s: ref must name the reviewed branch/tag, not repeat a commit SHA\n' "$key"
        failed=1
    fi
    if [[ $committag != "!!str" || ! $commit =~ ^sha1-[0-9a-f]{40}$ ]]; then
        printf 'INVALID %s: missing or malformed resolved commit\n' "$key"
        failed=1
    fi
    suffix=${key##*@}
    if [[ $suffix =~ ^[0-9a-fA-F]{40}$ && $commit != "sha1-${suffix,,}" ]]; then
        printf 'INVALID %s: literal-SHA key disagrees with resolved commit\n' "$key"
        failed=1
    fi
done <<< "$records"
echo "inspected $count dependency records; representation failures=$failed"
exit "$failed"
