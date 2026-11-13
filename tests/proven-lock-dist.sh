#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# The shipped artifact must be the proven source, and must behave as it does.
#
#   1. Regenerate dist/proven-lock/proven-lock-verdict.c from src/ with the
#      Idris2 RefC backend and require byte-identity with the committed file.
#      A kernel change that is not re-generated, or a hand edit of the C,
#      fails here.
#   2. Build the shipped C with scripts/build-proven-lock.sh, which is the
#      consumers' build, and run the whole fixture corpus (tests/proven-lock.sh)
#      against that binary.
#
# IDRIS2_SOURCE_DIR: an Idris2 checkout at the pinned commit to take the RefC
# runtime from (otherwise the build fetches it). No compiler is NOT RUN (exit 2).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
command -v idris2 >/dev/null || { echo "proven-lock-dist: idris2 missing; NOT RUN" >&2; exit 2; }
cd "$root"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/gen"
git archive HEAD src proven-lock.ipkg | tar -x -C "$tmp/gen"
(cd "$tmp/gen" && idris2 --codegen refc --build proven-lock.ipkg >"$tmp/gen.log" 2>&1) || {
  cat "$tmp/gen.log" >&2; echo "FAIL: the RefC generation did not complete" >&2; exit 1; }
if ! cmp -s "$tmp/gen/build/exec/proven-lock-verdict.c" dist/proven-lock/proven-lock-verdict.c; then
  echo "FAIL: dist/proven-lock/proven-lock-verdict.c is not the RefC output of src/ at HEAD" >&2
  echo "      regenerate: idris2 --codegen refc --build proven-lock.ipkg, then copy" >&2
  echo "      build/exec/proven-lock-verdict.c to dist/proven-lock/" >&2
  exit 1
fi
echo "ok: the shipped C is byte-identical to the RefC output of src/ at HEAD ($(sha256sum dist/proven-lock/proven-lock-verdict.c | cut -c1-16))"

args=("$tmp/verdict")
[[ -n ${IDRIS2_SOURCE_DIR:-} ]] && args+=(--runtime "$IDRIS2_SOURCE_DIR")
rc=0; bash scripts/build-proven-lock.sh "${args[@]}" || rc=$?
[[ $rc == 0 ]] || { echo "FAIL: the consumers' build of the shipped C did not complete (exit $rc)" >&2; exit 1; }

PROVEN_LOCK_VERDICT="$tmp/verdict" bash tests/proven-lock.sh > "$tmp/corpus.log" 2>&1 || {
  grep -v '^ok' "$tmp/corpus.log" >&2; echo "FAIL: the gcc build of the shipped C fails the fixture corpus" >&2; exit 1; }
echo "ok: the gcc build of the shipped C passes the fixture corpus ($(grep -c '^ok' "$tmp/corpus.log") checks)"
