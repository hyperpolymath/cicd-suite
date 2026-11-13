#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Controls for the stamped consumer gate (templates/proven-lock-gate.yml and
# scripts/proven-lock-gate.sh). Each design condition has a control:
#   stamp     body edit = drift; local-region edit = still matches; no stamp = NOT RUN
#   lint      NOT RUN must fail the job: no `if:` and no continue-on-error anywhere,
#             read-only token, explicit job names, a timeout
#   gate      consistent -> 0; lock defect -> 1; drifted copy -> 1 (drift)
#   selftest  a suite whose shipped C always says CONSISTENT -> 2 (not_run:selftest)
#   pin       a malformed pinned SHA -> 2 (not_run:pin), before any fetch
# PROVEN_IDRIS2_SOURCE_DIR: Idris2 checkout for the RefC runtime (else fetched).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
command -v yq >/dev/null && yq --version | grep -q mikefarah || { echo "proven-lock-gate: mikefarah yq missing; NOT RUN" >&2; exit 2; }
command -v gcc >/dev/null || { echo "proven-lock-gate: gcc missing; NOT RUN" >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
template=$root/templates/proven-lock-gate.yml
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL $*"; fail=1; }
expect_rc() { # NAME WANT CMD...
  local name=$1 want=$2 rc=0; shift 2
  "$@" >"$tmp/out" 2>&1 || rc=$?
  if [[ $rc == "$want" ]]; then ok "$name"; else bad "$name: wanted exit $want, got $rc"; sed 's/^/    /' "$tmp/out"; fi
}

# --- stamp
expect_rc 'the template matches its stamp' 0 bash "$root/scripts/proven-stamp.sh" check "$template"
sed 's/timeout-minutes: 15/timeout-minutes: 90/' "$template" > "$tmp/edited.yml"
expect_rc 'a body edit is drift' 1 bash "$root/scripts/proven-stamp.sh" check "$tmp/edited.yml"
sed -e 's/PROVEN_SHA: "0\{40\}"/PROVEN_SHA: "1111111111111111111111111111111111111111"/' \
    -e 's/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1/checkout@2222222222222222222222222222222222222222 # v7.1.0/' \
    "$template" > "$tmp/local.yml"
grep -q 1111111111 "$tmp/local.yml" && grep -q 2222222222 "$tmp/local.yml" || bad 'local-region control did not apply its edits'
expect_rc 'a local-region edit (suite pin, Dependabot bump) still matches' 0 bash "$root/scripts/proven-stamp.sh" check "$tmp/local.yml"
tail -n +2 "$template" > "$tmp/nostamp.yml"
expect_rc 'a copy without a stamp is NOT RUN' 2 bash "$root/scripts/proven-stamp.sh" check "$tmp/nostamp.yml"

# --- lint: NOT RUN must fail the job
ifs=$(yq '[.. | select(has("if"))] | length' "$template")
coe=$(yq '[.. | select(has("continue-on-error"))] | length' "$template")
[[ $ifs == 0 ]] && ok 'no if: anywhere (a skipped job would satisfy a required check)' || bad "if: found $ifs times"
[[ $coe == 0 ]] && ok 'no continue-on-error anywhere' || bad "continue-on-error found $coe times"
[[ $(yq -o json -I 0 '.permissions' "$template") == '{"contents":"read"}' ]] && ok 'token is read-only' || bad 'permissions are not exactly contents: read'
[[ $(yq '[.jobs[] | select(has("name") | not)] | length' "$template") == 0 ]] && ok 'every job has an explicit name (stable required context)' || bad 'a job has no explicit name'
[[ $(yq '[.jobs[] | select(has("timeout-minutes") | not)] | length' "$template") == 0 ]] && ok 'every job has a timeout' || bad 'a job has no timeout'

# --- pin refusal, from the template's own run script
yq '.jobs.proven-lock.steps[1].run' "$template" > "$tmp/run.sh"
rc=0; out=$(env -i PATH="$PATH" PROVEN_SHA=not-a-sha RUNNER_TEMP="$tmp/rt" bash "$tmp/run.sh" 2>&1) || rc=$?
[[ $rc == 2 && $out == *PROVEN_LOCK_CLASS=not_run:pin* ]] && ok 'a malformed pin is NOT RUN before any fetch' || bad "malformed pin: exit $rc, output: $out"

# --- gate end to end, with this checkout as the suite
workspace() { # FIXTURE -> $tmp/ws with the stamped gate installed
  rm -rf -- "$tmp/ws"; cp -R "$root/tests/fixtures/proven-lock/$1/repo" "$tmp/ws"
  mv "$tmp/ws/dot-github" "$tmp/ws/.github"
  cp "$template" "$tmp/ws/.github/workflows/proven-lock-gate.yml"
}
gate() { # WANT_RC WANT_CLASS NAME [SUITE]
  local want=$1 class=$2 name=$3 suite=${4:-$root} rc=0
  bash "$suite/scripts/proven-lock-gate.sh" "$tmp/ws" .github/workflows/proven-lock-gate.yml >"$tmp/out" 2>&1 || rc=$?
  if [[ $rc == "$want" ]] && tail -n 1 "$tmp/out" | grep -qx "PROVEN_LOCK_CLASS=$class"; then ok "$name"
  else bad "$name: wanted $want/$class, got $rc/$(tail -n 1 "$tmp/out")"; sed 's/^/    /' "$tmp/out" | tail -15; fi
}
workspace ok-tag-keyed;  gate 0 consistent 'a consistent lock passes the gate'
workspace self-sha-leaf; gate 1 defect 'a self-SHA leaf fails the gate as a defect'
workspace ok-tag-keyed;  sed -i 's/timeout-minutes: 15/timeout-minutes: 90/' "$tmp/ws/.github/workflows/proven-lock-gate.yml"
gate 1 drift 'an edited stamped copy fails as drift, before any build'

# --- self-test: a suite whose shipped C always answers CONSISTENT is refused
mkdir -p "$tmp/suite"
git -C "$root" archive HEAD dist scripts tests/fixtures/proven-lock | tar -x -C "$tmp/suite"
cp "$root/scripts/"*.sh "$tmp/suite/scripts/"
printf '#include <stdio.h>\nvoid *global_IORef_Storage;\nint main(void){puts("CONSISTENT");return 0;}\n' > "$tmp/suite/dist/proven-lock/proven-lock-verdict.c"
git -C "$tmp/suite" init -q && git -C "$tmp/suite" add -A && git -C "$tmp/suite" -c user.name=c -c user.email=c@invalid -c commit.gpgsign=false commit -qm counterfeit
workspace ok-tag-keyed
gate 2 not_run:selftest 'a counterfeit always-CONSISTENT binary is refused by the self-test' "$tmp/suite"

exit "$fail"
