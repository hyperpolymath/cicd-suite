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
# missing, yq is unavailable, or a planted control did not trip.
set -euo pipefail
cd "$(dirname "$0")/.."

ALLOWED_OWNERS='^(actions|github|hyperpolymath|dtolnay|swatinem|goto-bus-stop|taiki-e)$'
GATES=(rust-ci creusot-gate spark-gate kanren-gate)

command -v yq >/dev/null || { echo "yq is required (mikefarah v4)"; exit 2; }

# Scan a workflow file's `uses` values against ALLOWED_OWNERS and the
# full-SHA pin requirement.
#   $1 - path to the workflow file to check
# Prints one "FAIL <file>: uses <ref> — <reason>" line per violation found.
# Returns 0 when every `uses:` ref is from an allowed owner and pinned at a
# full 40-hex commit SHA; 1 if any ref fails either check.
check_file() { # <workflow file> -> prints violations, returns 1 if any
    local f="$1" refs ref owner bad=0
    # Parse quoted keys, flow mappings and aliases as YAML. Capture the
    # status before iterating: a failed process substitution would look empty
    # and silently pass. An empty extraction is also a failure for these gates.
    if ! refs="$(yq -r 'explode(.) | .. | select(tag == "!!map") | select(has("uses")) | .uses' "$f")"; then
        echo "FAIL $f: cannot inspect workflow YAML"; return 1
    fi
    if [ -z "$refs" ]; then
        echo "FAIL $f: no action references found"; return 1
    fi
    while IFS= read -r ref; do
        owner="${ref%%/*}"
        if ! [[ "$owner" =~ $ALLOWED_OWNERS ]]; then
            echo "FAIL $f: uses $ref — owner '$owner' is outside the set every caller's Actions policy admits"; bad=1
        fi
        if ! [[ "$ref" =~ @[0-9a-f]{40}$ ]]; then
            echo "FAIL $f: uses $ref — not pinned at a full 40-hex commit SHA (sha_pinning_required)"; bad=1
        fi
    done <<< "$refs"
    return "$bad"
}

fail=0
for g in "${GATES[@]}"; do
    f=".github/workflows/$g.yml"
    [ -f "$f" ] || { echo "NO CHECK: $f is missing"; exit 2; }
    if check_file "$f"; then echo "ok   $f"; else fail=1; fi
done

# Planted controls: the guard must refuse both violations in each YAML
# layout, including the exact ref that killed the first live caller.
tmp=$(mktemp)
trap 'rm -f "$tmp" "${tmp}.valid"' EXIT
check_control() {
    local layout="$1" output n
    if output="$(check_file "$tmp")"; then
        echo "NO CHECK: $layout planted violations were not refused"; exit 2
    fi
    n=$(printf '%s\n' "$output" | grep -c '^FAIL' || true)
    [ "$n" -eq 2 ] || { echo "NO CHECK: $layout expected 2 planted failures, saw $n"; exit 2; }
    # The same layout must accept allowed owners at full SHAs.
    sed 's#embarkstudios/cargo-deny-action#actions/checkout#g; s#@v7.0.1#@3c6349835b2b7b196a839186cb8b78e02f7b5f25#g' "$tmp" > "${tmp}.valid"
    if ! check_file "${tmp}.valid"; then
        echo "NO CHECK: $layout valid references were refused"; exit 2
    fi
    echo "ok   planted control: $layout accepts full SHAs and refuses a disallowed owner and a tag pin"
}
for key in uses "'uses'" '"uses"' 'uses '; do
    printf 'jobs:\n  a:\n    steps:\n      - %s: embarkstudios/cargo-deny-action@3c6349835b2b7b196a839186cb8b78e02f7b5f25\n      - %s: actions/checkout@v7.0.1\n' "$key" "$key" > "$tmp"
    check_control "key $key"
done
printf 'jobs: {a: {steps: [{uses : embarkstudios/cargo-deny-action@3c6349835b2b7b196a839186cb8b78e02f7b5f25}, {"uses": actions/checkout@v7.0.1}]}}\n' > "$tmp"
check_control 'flow mappings'

printf 'jobs: [\n' > "$tmp"
if check_file "$tmp" >/dev/null 2>&1; then
    echo "NO CHECK: malformed YAML was accepted"; exit 2
fi
echo "ok   planted control: malformed YAML fails"

if [ "$fail" -ne 0 ]; then
    echo "gate-action-owners: a gate uses an action the estate's Actions policy would refuse at the caller's startup."; exit 1
fi
echo "gate-action-owners: every gate ref is an allowed owner at a full SHA"
