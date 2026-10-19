#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# gate-action-owners.sh — every `uses:` in the four language gates names an
# owner the estate's GitHub Actions policy admits, at a full commit SHA.
#
# MEASURED 2026-10-19 (plasma-parser-writer#108, run 39251770946): a caller of
# rust-ci.yml died at startup with
#   The action embarkstudios/cargo-deny-action@3c634983… is not allowed in
#   hyperpolymath/plasma-parser-writer because all actions must be from a
#   repository owned by hyperpolymath, created by GitHub, verified in the
#   GitHub Marketplace, or match one of the patterns: …
# while creusot-gate.yml from the same commit ran. The policy is evaluated in
# the CALLER's repository, so a reusable can only use what every caller is
# allowed, and nothing in cicd-suite's own CI would ever see the refusal.
# This guard is that refusal, moved to where a change to a gate is reviewed.
#
# The allowed set is the owners the gates use today and that estate
# repositories run green with: actions/* and github/* (GitHub-made),
# hyperpolymath/* (owned), dtolnay and swatinem (Marketplace-verified), and
# goto-bus-stop and taiki-e (used by standards' and hypatia's green
# workflows). Adding an owner here is a claim that every caller's policy
# admits it: prove it on a caller first.
#
# Exit 0 when every ref passes; 1 on any violation; 2 when a gate file is
# missing or the planted control did not trip (the guard cannot fail).
set -euo pipefail
cd "$(dirname "$0")/.."

ALLOWED_OWNERS='^(actions|github|hyperpolymath|dtolnay|swatinem|goto-bus-stop|taiki-e)$'
GATES=(rust-ci creusot-gate spark-gate kanren-gate)

# Scan a workflow file's `uses:` lines against ALLOWED_OWNERS and the
# full-SHA pin requirement.
#   $1 - path to the workflow file to check
# Prints one "FAIL <file>: uses <ref> — <reason>" line per violation found.
# Returns 0 when every `uses:` ref is from an allowed owner and pinned at a
# full 40-hex commit SHA; 1 if any ref fails either check.
check_file() { # <workflow file> -> prints violations, returns 1 if any
    local f="$1" ref owner bad=0
    while IFS= read -r ref; do
        owner="${ref%%/*}"
        if ! [[ "$owner" =~ $ALLOWED_OWNERS ]]; then
            echo "FAIL $f: uses $ref — owner '$owner' is outside the set every caller's Actions policy admits"; bad=1
        fi
        if ! [[ "$ref" =~ @[0-9a-f]{40}$ ]]; then
            echo "FAIL $f: uses $ref — not pinned at a full 40-hex commit SHA (sha_pinning_required)"; bad=1
        fi
    done < <(grep -oE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[^[:space:]#]+' "$f" | sed -E 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*//')
    return "$bad"
}

fail=0
for g in "${GATES[@]}"; do
    f=".github/workflows/$g.yml"
    [ -f "$f" ] || { echo "NO CHECK: $f is missing"; exit 2; }
    if check_file "$f"; then echo "ok   $f"; else fail=1; fi
done

# Planted control: the guard must be able to fail, on the exact ref that
# killed the first live caller.
tmp=$(mktemp)
printf 'jobs:\n  a:\n    steps:\n      - uses: embarkstudios/cargo-deny-action@3c6349835b2b7b196a839186cb8b78e02f7b5f25\n      - uses: actions/checkout@v7.0.1\n' > "$tmp"
if check_file "$tmp" >/dev/null 2>&1; then
    echo "NO CHECK: the planted disallowed owner and the planted tag pin were not refused — the guard cannot fail"; rm -f "$tmp"; exit 2
fi
n=$(check_file "$tmp" 2>/dev/null | grep -c '^FAIL' || true); rm -f "$tmp"
[ "$n" -eq 2 ] || { echo "NO CHECK: expected 2 planted failures, saw $n"; exit 2; }
echo "ok   planted control: a disallowed owner and a tag pin are both refused"

if [ "$fail" -ne 0 ]; then
    echo "gate-action-owners: a gate uses an action the estate's Actions policy would refuse at the caller's startup."; exit 1
fi
echo "gate-action-owners: every gate ref is an allowed owner at a full SHA"
