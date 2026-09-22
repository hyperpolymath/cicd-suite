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

# A self-referencing BRANCH pin is how every downstream consumer reaches these
# composites: `uses: hyperpolymath/cicd-suite/actions/x@main` is resolved by the
# runner to the COMMIT THE LOCKFILE NAMES, not to the branch tip. So if actions/
# has changed since that locked commit, every consumer silently runs the OLD
# gates while this repo's own CI runs the new ones — the cure lands here and is
# inert everywhere else, with nothing red to show for it.
#
# Measured 2026-09-22: fa71ac2 (#32) and 0c1bc9f (#34) both cured the composite
# `-e` kill, and pons-asinorum's estate audit still died on it at 82ms, because
# the lock still pinned cicd-suite@main at 9adb3908 — four commits back. The
# house pattern is a follow-up "pin cicd-suite lock at <sha>" commit (f8c8f4a,
# 4f9a7a4, 373714a); #32 and #34 never got one. This asserts it instead.
#
# Needs full history: the job running this must use fetch-depth: 0.
echo "== a self-referencing branch pin serves the CURRENT composites =="
# ERE has no lazy quantifiers, so strip .git FIRST and then take owner/repo.
# In Actions $GITHUB_REPOSITORY is authoritative; the remote is the local path.
selfrepo="${GITHUB_REPOSITORY:-$(git -C "$ROOT" remote get-url origin 2>/dev/null \
    | sed -E 's#\.git$##; s#^.*[:/]([^/]+/[^/]+)$#\1#')}"
selfchecked=0
while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    case "$ref" in "$selfrepo@"*) ;; *) continue ;; esac
    case "${ref#*@}" in *[!0-9a-f]*) ;; *) continue ;; esac   # a SHA pin cannot drift
    selfchecked=$((selfchecked+1))
    locked="$(r="$ref" yqr '.dependencies[strenv(r)].commit' "$LOCK" | sed 's/^sha1-//')"
    if ! git -C "$ROOT" cat-file -e "$locked^{commit}" 2>/dev/null; then
        bad "$ref pins $locked, which is not in this clone (need fetch-depth: 0)"
        continue
    fi
    have="$(git -C "$ROOT" rev-parse "$locked:actions" 2>/dev/null || true)"
    want="$(git -C "$ROOT" rev-parse "HEAD:actions" 2>/dev/null || true)"
    if [ -n "$have" ] && [ "$have" = "$want" ]; then
        ok "$ref serves the current actions/ tree ($locked)"
    else
        bad "$ref pins $locked, whose actions/ tree differs from HEAD"
        echo "       every consumer using this branch ref runs those OLD composites;"
        echo "       a cure landed here is inert downstream. Changed since the pin:"
        git -C "$ROOT" diff --name-only "$locked" HEAD -- actions/ 2>/dev/null \
            | sed 's/^/         /' | head -8
    fi
done < <(yqr '.dependencies | keys | .[]' "$LOCK")

# This block printed its header and checked NOTHING on its first run — a broken
# sed left ".git" on the repo name so no key ever matched, and the section above
# only asserts non-vacuity for its own population. A header is not a check.
if [ "$selfchecked" -eq 0 ]; then
    bad "no self-referencing branch pin examined (selfrepo='$selfrepo') — this section is vacuous"
else
    ok "examined $selfchecked self-referencing branch pin(s)"
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
