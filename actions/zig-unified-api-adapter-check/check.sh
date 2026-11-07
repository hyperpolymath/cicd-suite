#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
# This is a scoped lexical policy check, not an effect or import analysis.
# Callers narrowing the scope must include the FFI implementation's imports.
fail() { echo "::error::$*" >&2; exit 1; }
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
git ls-files -z -- '*.zig' > "$tmp" || fail 'cannot enumerate tracked Zig sources'
mapfile -d '' -t sources < "$tmp"
selected=()
if [[ -n ${FFI_PATHS:-} ]]; then
    while IFS= read -r path || [[ -n "$path" ]]; do
        [[ -n "$path" ]] || continue
        # Literal repository-relative roots: no negative patterns or traversal.
        [[ "$path" != /* && "$path" != -* && "$path" != :* && "$path" != *'..'* && "$path" != *'*'* && "$path" != *'?'* ]] \
            || fail "invalid FFI source root: $path"
        path=${path%/}
        matched=0
        for source in "${sources[@]}"; do
            if [[ "$source" == "$path" || "$source" == "$path/"* ]]; then
                selected+=("$source"); matched=1
            fi
        done
        [[ $matched == 1 ]] || fail "FFI source root matches no tracked Zig files: $path"
    done <<< "$FFI_PATHS"
    [[ ${#selected[@]} -gt 0 ]] || fail 'explicit FFI scope is empty'
else
    selected=("${sources[@]}")
fi
if [[ ${#selected[@]} == 0 ]]; then
    echo 'NOT APPLICABLE: no tracked Zig sources'
    exit 0
fi
for source in "${selected[@]}"; do
    [[ -f "$source" ]] || fail "missing tracked source: $source"
    if grep -nE 'std\.fs|std\.io' -- "$source"; then
        fail "Zig FFI source $source uses prohibited direct std.fs/std.io"
    else
        result=$?
        [[ $result == 1 ]] || fail "cannot scan $source (grep exit $result)"
    fi
done
echo "Zig FFI lexical policy: checked ${#selected[@]} source files"
