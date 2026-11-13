#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Fixture runner for the proven lock kernel. Each case under
# tests/fixtures/proven-lock/<case>/ has repo/, optional oracle.json and
# `expected` (first line, then sorted REASON lines). UNJUDGED/WHY lines are
# not compared. Exit: 0 all ok, 1 a case failed, 2 NOT RUN (missing tool).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
fixtures="$here/fixtures/proven-lock"
export PATH="$HOME/.idris2/bin:$PATH"

notrun() { printf 'proven-lock tests: %s; NOT RUN\n' "$1" >&2; exit 2; }
if [[ -z ${PROVEN_LOCK_VERDICT:-} ]]; then
  command -v idris2 >/dev/null || notrun "idris2 is not installed"
fi
command -v jq >/dev/null || notrun "jq is not installed"
command -v yq >/dev/null || notrun "yq is not installed"
yq --version 2>/dev/null | grep -q mikefarah || notrun "mikefarah yq v4 is required"

# PROVEN_LOCK_VERDICT runs the corpus against a prebuilt binary, such as the
# gcc build of the shipped C (tests/proven-lock-dist.sh).
if [[ -n ${PROVEN_LOCK_VERDICT:-} ]]; then
  verdict=$PROVEN_LOCK_VERDICT
else
  (cd "$repo" && idris2 --build proven-lock.ipkg >/dev/null) || { echo "FAIL: the kernel does not build" >&2; exit 1; }
  verdict="$repo/build/exec/proven-lock-verdict"
fi
[[ -x $verdict ]] || notrun "kernel binary missing"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# observe ROOT [ORACLE] -> prints first line + sorted REASON lines
observe() {
  local root=$1 oracle=${2:-} facts="$tmp/facts.json" out rc
  local args=("$root")
  [[ -n $oracle ]] && args+=(--oracle "$oracle")
  set +e
  "$repo/scripts/extract-lock-facts.sh" "${args[@]}" > "$facts" 2>"$tmp/err"
  rc=$?
  if [[ $rc -eq 2 ]]; then
    set -e; echo NOT_RUN; return 0
  elif [[ $rc -ne 0 ]]; then
    set -e; echo "EXTRACTOR_EXIT_$rc"; return 0
  fi
  out=$("$verdict" "$facts" 2>/dev/null)
  set -e
  printf '%s\n' "$out" | head -n 1
  printf '%s\n' "$out" | tail -n +2 | grep -a '^REASON'$'\t' | LC_ALL=C sort || true
}

fail=0 count=0
for dir in "$fixtures"/*/; do
  name=$(basename "$dir")
  [[ -d $dir/repo && -f $dir/expected ]] || continue
  count=$((count + 1))
  oracle=
  [[ -f $dir/oracle.json ]] && oracle="$dir/oracle.json"
  # Fixture trees store their workflows under dot-github/, never .github/: they
  # are deliberately defective inputs, and at a .github/workflows path every
  # workflow scanner (SonarCloud, CodeQL, Hypatia) would read them as live.
  rm -rf -- "$tmp/case"
  cp -R "$dir/repo" "$tmp/case"
  [[ -d $tmp/case/dot-github ]] && mv "$tmp/case/dot-github" "$tmp/case/.github"
  observe "$tmp/case" "$oracle" > "$tmp/got"
  { head -n 1 "$dir/expected"; tail -n +2 "$dir/expected" | LC_ALL=C sort; } > "$tmp/want"
  if diff -u "$tmp/want" "$tmp/got" > "$tmp/diff"; then
    echo "ok $name"
  else
    echo "FAIL $name"
    sed 's/^/    /' "$tmp/diff"
    fail=1
  fi
done

[[ $count -gt 0 ]] || { echo "FAIL: no fixture cases found" >&2; exit 1; }

# --json (the squabbler executor contract) must agree with the text verdict on
# every fixture: same exit code, every line valid JSON, one finding object per
# REASON line, and a final status object naming the same verdict.
json_agrees() { # CASE_ROOT ORACLE
  local oracle=$2 args=("$1") trc jrc text json
  [[ -n $oracle ]] && args+=(--oracle "$oracle")
  "$repo/scripts/extract-lock-facts.sh" "${args[@]}" > "$tmp/facts.json" 2>/dev/null || return 0
  text=$("$verdict" "$tmp/facts.json" 2>/dev/null) && trc=0 || trc=$?
  json=$("$verdict" --json "$tmp/facts.json" 2>/dev/null) && jrc=0 || jrc=$?
  [[ $trc == "$jrc" ]] || { echo "exit $trc vs $jrc"; return 1; }
  jq -e . >/dev/null <<<"$json" || { echo "invalid JSON"; return 1; }
  [[ $(jq -sr 'last.verdict' <<<"$json") == "$(head -n 1 <<<"$text")" ]] || { echo "verdict differs"; return 1; }
  [[ $(jq -s '[.[] | select(has("reason"))] | length' <<<"$json") == "$(grep -c '^REASON' <<<"$text" || true)" ]] || { echo "finding count differs"; return 1; }
}
for dir in "$fixtures"/*/; do
  name=$(basename "$dir")
  [[ -d $dir/repo && -f $dir/expected ]] || continue
  rm -rf -- "$tmp/case"; cp -R "$dir/repo" "$tmp/case"
  [[ -d $tmp/case/dot-github ]] && mv "$tmp/case/dot-github" "$tmp/case/.github"
  oracle=; [[ -f $dir/oracle.json ]] && oracle="$dir/oracle.json"
  if why=$(json_agrees "$tmp/case" "$oracle"); then echo "ok json $name"; else echo "FAIL json $name: $why"; fail=1; fi
done

# The repository's own lock must be consistent.
self=$(observe "$repo")
if [[ $(printf '%s\n' "$self" | head -n 1) == CONSISTENT ]]; then
  echo "ok repository-root"
else
  echo "FAIL repository-root"
  printf '%s\n' "$self" | sed 's/^/    /'
  fail=1
fi

exit "$fail"
