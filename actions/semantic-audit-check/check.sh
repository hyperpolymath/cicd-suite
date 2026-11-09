#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check.sh — the semantic-audit gate's entry point.
#
# The decision logic lives in src/ (Idris2, compiled fresh from this tree on
# every run — the sources ARE the audit trail). This wrapper owns only the
# OS glue: enter the working directory, build the checker, map exit codes to
# the estate contract. an absent idris2 is NOT a pass:
#
# Exit codes: 0 passed/not_applicable · 1 defect(s) · 2 NO CHECK WAS PERFORMED.
# Outputs (to $GITHUB_OUTPUT): status=passed|failed|not_applicable|not_run
#
# Env: WORKING_DIRECTORY (default "."),
#      SEMANTIC_AUDIT_CHECK_BIN (prebuilt checker, used by tests; never set in consumers).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate="semantic-audit-check"
dir="${WORKING_DIRECTORY:-.}"

note_not_run() { # <reason>
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "status=not_run" >> "$GITHUB_OUTPUT"
  echo "::error::$gate: $1 — NO CHECK WAS PERFORMED (status=not_run)." >&2
  exit 2
}

cd "$dir" || note_not_run "cannot enter $dir"

bin="${SEMANTIC_AUDIT_CHECK_BIN:-}"
if [ -z "$bin" ]; then
  command -v idris2 >/dev/null 2>&1 \
    || note_not_run "idris2 is not on PATH (the audit is written in Idris2; see docs/assurance/SUITE-CLOSEOUT.adoc for the bootstrap pin)"
  build_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/$gate-build-XXXXXXXX")" \
    || note_not_run "cannot create a build directory"
  trap 'rm -rf "$build_dir"' EXIT
  cp -R "$HERE/src" "$HERE/$gate.ipkg" "$build_dir/" || note_not_run "cannot stage the checker sources"
  if ! (cd "$build_dir" && idris2 --build "$gate.ipkg") > "$build_dir/build.log" 2>&1; then
    sed 's/^/  /' "$build_dir/build.log" >&2
    note_not_run "the checker failed to compile (build log above); this is a toolchain fault, not a repository result"
  fi
  bin="$build_dir/build/exec/$gate"
fi

args=()
[ -n "${GITHUB_OUTPUT:-}" ] && args+=(--github-output "$GITHUB_OUTPUT")

"$bin" "${args[@]}"
rc=$?
case "$rc" in
  0|1|2) exit "$rc" ;;
  *) note_not_run "the checker exited with unexpected code $rc" ;;
esac
