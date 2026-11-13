#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# build-proven-lock.sh OUT [--runtime IDRIS2_SOURCE_DIR]
#
# Builds the proven lock verdict from the generated C this repository ships
# (dist/proven-lock/proven-lock-verdict.c) and the Idris2 RefC runtime sources.
# This repository's CI and consumers build it the same way.
#
# The runtime comes from idris-lang/Idris2 at the same commit that generated
# the C (IDRIS2_SOURCE_SHA below). It is fetched, not vendored, so no
# third-party licence files are copied into this repository. With --runtime,
# an existing Idris2 checkout is used instead, and it must be at that commit.
#
# Trusted base of the resulting binary, stated so a green is not over-read:
# the two named axioms in src/Proven/Lock/Axioms.idr, the Idris2 compiler that
# generated the C, the RefC runtime, gcc and libgmp.
#
# Exit: 0 built; 2 NOT RUN (missing gcc or gmp.h, fetch failed, wrong runtime
# commit, compile failed). A build that cannot finish is never a verdict.
set -euo pipefail

readonly IDRIS2_SOURCE_SHA=27780073c8631826d846499840b3857d9b9a4fd5
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
notrun() { printf 'build-proven-lock: %s; NOT RUN\n' "$1" >&2; exit 2; }

out=${1:-}
[[ -n $out ]] || notrun "usage: build-proven-lock.sh OUT [--runtime IDRIS2_SOURCE_DIR]"
shift
runtime=
while [[ $# -gt 0 ]]; do
  case $1 in
    --runtime) runtime=${2:-}; shift 2 ;;
    *) notrun "unknown argument $1" ;;
  esac
done

src=$here/dist/proven-lock/proven-lock-verdict.c
[[ -f $src ]] || notrun "generated C missing: $src"
command -v gcc >/dev/null || notrun "gcc is not installed"
printf '#include <gmp.h>\n' | gcc -x c -fsyntax-only - 2>/dev/null ||
  notrun "gmp.h not found (install libgmp-dev)"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
if [[ -z $runtime ]]; then
  runtime=$tmp/idris2
  git init -q "$runtime"
  git -C "$runtime" remote add origin https://github.com/idris-lang/Idris2.git
  git -C "$runtime" config core.sparseCheckout true
  printf 'support/refc/\nsupport/c/\n' > "$runtime/.git/info/sparse-checkout"
  fetched=0
  for delay in 0 5 15; do
    sleep "$delay"
    if git -C "$runtime" fetch -q --depth=1 origin "$IDRIS2_SOURCE_SHA" 2>/dev/null; then
      fetched=1; break
    fi
  done
  [[ $fetched == 1 ]] || notrun "could not fetch the Idris2 runtime at $IDRIS2_SOURCE_SHA"
  git -C "$runtime" checkout -q --detach FETCH_HEAD || notrun "could not check out the Idris2 runtime"
fi
actual=$(git -C "$runtime" rev-parse HEAD 2>/dev/null) || notrun "runtime is not a git checkout"
[[ $actual == "$IDRIS2_SOURCE_SHA" ]] || notrun "runtime is at $actual, not $IDRIS2_SOURCE_SHA"

refc=$runtime/support/refc cdir=$runtime/support/c
compgen -G "$refc/*.c" >/dev/null && compgen -G "$cdir/*.c" >/dev/null ||
  notrun "runtime sources missing under $runtime/support"
gcc -O2 -w -I"$refc" -I"$cdir" -o "$out" "$src" "$refc"/*.c "$cdir"/*.c -lgmp -lm ||
  notrun "compile failed"
echo "built $out from $(sha256sum "$src" | cut -c1-16) with the RefC runtime at ${IDRIS2_SOURCE_SHA:0:12}"
