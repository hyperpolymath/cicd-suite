#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
check=$(cd "$(dirname "$0")/../actions/zig-unified-api-adapter-check" && pwd)/check.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
git init -q
mkdir -p ffi tools
printf 'pub fn pure() void {}\n' > ffi/api.zig
printf 'const file = std.fs.cwd();\n' > tools/main.zig
git add .
FFI_PATHS=ffi bash "$check"
reject() { if FFI_PATHS="$1" bash "$check" > result.log 2>&1; then echo "unexpected pass: $1" >&2; exit 1; fi; }
reject ''
reject absent
reject ':!tools'
reject '../ffi'
printf 'const file = std.fs.cwd();\n' > ffi/api.zig
reject ffi
printf 'pub fn pure() void {}\n' > ffi/api.zig
rm ffi/api.zig
reject ffi
echo 'PASS: explicit FFI scope permits CLI I/O, catches FFI I/O, and rejects missing/invalid scope and missing sources'
