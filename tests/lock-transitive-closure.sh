#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# actions.lock transitive-closure test.
#
# An onboarded workflow may invoke a same-repo composite as `uses: $/actions/x`.
# That ref is inherently pinned (it resolves at the running commit) and needs no
# lockfile entry of its own — but the runner ALSO validates that composite's
# internals against the lock, and it does so against the *calling workflow's*
# entry in the `workflows:` map. A remote ref reached only through a composite
# must therefore be listed under every workflow that reaches it, or the run dies
# in `Set up job` with `lockfile missing pin for ...` before a step executes.
#
# Why this test exists rather than a comment in the lockfile:
#
#   ecd0240 (#16)  added the two transitive SHA refs for code-hygiene-self-test
#   ...            they survived #17, #18, #25 — `Gate controls` was green
#   3b4afaf (#28)  regenerated the lock and SILENTLY DROPPED both
#
# `gh actions-lock`'s extractor reads step-level `uses:` only. It cannot derive
# a ref reached through a composite, so a regenerate deletes any added by hand —
# and `gh actions-lock --verify` then returns rc=0 on the result. #28's own
# commit message says it "pins the SHA-form transitive deps reached via called
# reusables"; its diff removes exactly those, and its cited proof was that same
# rc=0. The tool cannot see the defect it creates, so the lockfile needs a gate
# that is not the tool. `--no-fix` still reports "Scanning 4 workflows", rc=0,
# against the broken file.
#
# Measured 2026-09-22, run 35786094563 (push, main, fa71ac2):
#   ##[error]lockfile missing pin for hyperpolymath/deed-ecosystem@f9d999b6...
#   Gate controls: failure (1 steps)   <- dead before a single step ran
#
# Usage: lock-transitive-closure.sh [lockfile]   (a path lets the mutant run)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="${1:-$ROOT/.github/workflows/actions.lock}"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

command -v yq >/dev/null || { echo "yq is required (Y-1: gates read YAML with yq, never grep)"; exit 2; }
[ -f "$LOCK" ] || { echo "no lockfile at $LOCK"; exit 2; }

# yq here is mikefarah v4. `--arg` and `// empty` are jq-only and fail as a
# LEXER ERROR, which a stray 2>/dev/null turns into a clean empty result and a
# vacuous pass. Errors stay visible on purpose; the expressions below are the
# mikefarah forms (strenv / select(. != null)).
yqr() { yq -r "$@"; }

# owner/repo/subpath@ref -> owner/repo@ref, the shape lock keys use.
lock_key() { printf '%s\n' "$1" | sed -E 's#^([^/]+/[^/@]+)(/[^@]*)?@(.*)$#\1@\3#'; }

# Every remote ref a workflow reaches through same-repo ($/) composites,
# following nested composites to a fixpoint.
closure_of_workflow() { # <workflow path relative to ROOT>
    local wf="$ROOT/$1" seen=" " queue=() cur act ref
    [ -f "$wf" ] || return 0
    while IFS= read -r cur; do
        [ -n "$cur" ] && queue+=("${cur#\$/}")
    done < <(yqr '.jobs[].steps[].uses | select(. != null)' "$wf" | grep '^\$/' || true)
    while [ "${#queue[@]}" -gt 0 ]; do
        cur="${queue[0]}"; queue=("${queue[@]:1}")
        case "$seen" in *" $cur "*) continue ;; esac
        seen="$seen$cur "
        act="$ROOT/$cur/action.yml"
        [ -f "$act" ] || continue
        while IFS= read -r ref; do
            [ -n "$ref" ] || continue
            case "$ref" in
                '$/'*) queue+=("${ref#\$/}") ;;  # nested same-repo composite
                ./*)   ;;                         # legacy local ref: not lockable
                *)     lock_key "$ref" ;;
            esac
        done < <(yqr '.runs.steps[].uses | select(. != null)' "$act")
    done
}

echo "== every ref reached through a \$/ composite is declared for its workflow =="
checked=0
while IFS= read -r wf; do
    [ -n "$wf" ] || continue
    declared="$(w="$wf" yqr '.workflows[strenv(w)][]' "$LOCK" 2>/dev/null || true)"
    while IFS= read -r need; do
        [ -n "$need" ] || continue
        checked=$((checked+1))
        if printf '%s\n' "$declared" | grep -qxF "$need"; then
            ok "$wf declares $need"
        else
            bad "$wf reaches $need through a composite but does not declare it"
            echo "       this is the shape that kills the job in Set up job, 1 step, no gate run"
        fi
    done < <(closure_of_workflow "$wf" | sort -u)
done < <(yqr '.workflows | keys | .[]' "$LOCK")

# A closure test with nothing to check is vacuous, and this repo HAS such edges
# (manifest-check reaches two). Assert the population is non-empty — this very
# assertion caught a jq-vs-mikefarah dialect bug on the first run of this file.
if [ "$checked" -eq 0 ]; then
    bad "no composite-reached refs found at all — the test is vacuous"
else
    ok "checked $checked composite-reached ref(s) — population is non-empty"
fi

echo "== every declared ref resolves to a dependencies: entry =="
while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    if r="$ref" yq -e '.dependencies[strenv(r)]' "$LOCK" >/dev/null 2>&1; then
        ok "dependencies: defines $ref"
    else
        bad "workflows: names $ref but dependencies: has no such key"
    fi
done < <(yqr '.workflows[][]' "$LOCK" | sort -u)

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
