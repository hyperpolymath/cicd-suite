#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# De-onboard prune test: scripts/deonboard-workflow.sh and its estate-audit
# entry point, scripts/deonboard-estate-audit.sh.
#
# The script removes a workflow from a consumer's actions.lock and prunes the
# dependencies nothing else reaches. Pruning one that IS still reached leaves
# a dangling edge, and a dangling edge kills the run at startup (standards
# scripts/close-lock.sh). That is the defect this test pins down:
# gh actions-lock writes nested `uses:` in lower case, so a record key
# 'Swatinem/rust-cache@<sha>' is reached by the edge
# 'swatinem/rust-cache@<sha>', and a byte-for-byte compare called it orphaned
# (measured on hyperpolymath/januskey's lock, 2026-10-14).
#
# Both entry points are run, because the fix once landed in one copy and not
# the other. A mutant of deonboard-workflow.sh with the byte-for-byte compare
# restored must fail through BOTH: through the wrapper too, or the wrapper is
# not delegating and this suite proves nothing about it.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF=".github/workflows/main-estate-audit.yml"
RUST_CACHE='Swatinem/rust-cache@6323deb102c322ba6fcbdcafc7e3dddab59af2b6'
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

command -v yq >/dev/null || { echo "yq is required (Y-1: gates read YAML with yq, never grep)"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A consumer lock in gh-actions-lock's layout: the audit copy reaches
# cicd-suite@main and, through it, deed-ecosystem; rust-ci reaches standards,
# whose record lists rust-cache in lower case under a mixed-case record key.
make_fixture() { # <dir>
  mkdir -p "$1/.github/workflows"
  cat > "$1/.github/workflows/actions.lock" <<'EOF'
version: 'v0.0.2'
workflows:
    '.github/workflows/main-estate-audit.yml':
        - 'actions/checkout@v7.0.1'
        - 'hyperpolymath/cicd-suite@main'
    '.github/workflows/rust-ci.yml':
        - 'hyperpolymath/standards@7d2041a2315572d8257341449257e6cfddc9aebc'
dependencies:
    'actions/checkout@v7.0.1':
        ref: 'v7.0.1'
        commit: 'sha1-3d3c42e5aac5ba805825da76410c181273ba90b1'
        owner_id: 44036562
        repo_id: 197814629
    'hyperpolymath/cicd-suite@main':
        ref: 'main'
        commit: 'sha1-5a10b72e574ef63855fafd4568a4c178657f3294'
        owner_id: 6759885
        repo_id: 1326697643
        uses:
            - 'hyperpolymath/deed-ecosystem@f9d999b60cb5f383679ea19912bcdc49c944973a'
    'hyperpolymath/deed-ecosystem@f9d999b60cb5f383679ea19912bcdc49c944973a':
        ref: 'main'
        commit: 'sha1-f9d999b60cb5f383679ea19912bcdc49c944973a'
        owner_id: 6759885
        repo_id: 1275649586
    'hyperpolymath/standards@7d2041a2315572d8257341449257e6cfddc9aebc':
        ref: '7d2041a2315572d8257341449257e6cfddc9aebc'
        commit: 'sha1-7d2041a2315572d8257341449257e6cfddc9aebc'
        owner_id: 6759885
        repo_id: 1116521501
        uses:
            - 'swatinem/rust-cache@6323deb102c322ba6fcbdcafc7e3dddab59af2b6'
    'Swatinem/rust-cache@6323deb102c322ba6fcbdcafc7e3dddab59af2b6':
        ref: 'v2'
        commit: 'sha1-6323deb102c322ba6fcbdcafc7e3dddab59af2b6'
        owner_id: 580492
        repo_id: 298565987
EOF
}

# De-onboard main-estate-audit.yml from <fixture> through one entry point of
# the scripts in <scripts-dir>.
deonboard() { # <scripts-dir> <wrapper|generic> <fixture>
  case "$2" in
    wrapper) bash "$1/deonboard-estate-audit.sh" "$3" ;;
    generic) bash "$1/deonboard-workflow.sh" "$3" "$WF" ;;
  esac
}

has_dep() { k="$2" yq -e '.dependencies | has(strenv(k))' "$1/.github/workflows/actions.lock" >/dev/null 2>&1; }

# Every edge (a workflows: ref or a nested uses:) must name a record, owner and
# repository compared case-insensitively as GitHub does.
dangling() { # <dir> -> prints dangling edges
  local lock="$1/.github/workflows/actions.lock"
  lower() { awk '{ i = index($0, "@"); print tolower(substr($0, 1, i - 1)) substr($0, i) }'; }
  { yq '.workflows[][]' "$lock"; yq '.dependencies[] | select(has("uses")) | .uses[]' "$lock"; } \
    | lower | sort -u | grep -vxF -f <(yq '.dependencies | keys | .[]' "$lock" | lower) || true
}

for entry in wrapper generic; do
  echo "== the fixed script, through the $entry entry point =="
  FIX="$WORK/fixed-$entry"; make_fixture "$FIX"
  if out="$(deonboard "$ROOT/scripts" "$entry" "$FIX" 2>&1)"; then ok "exits 0"; else bad "exits non-zero: $out"; fi
  if w="$WF" yq -e '.workflows | has(strenv(w))' "$FIX/.github/workflows/actions.lock" >/dev/null 2>&1; then
    bad "main-estate-audit.yml is still onboarded"
  else
    ok "main-estate-audit.yml is de-onboarded"
  fi
  for k in 'hyperpolymath/cicd-suite@main' 'hyperpolymath/deed-ecosystem@f9d999b60cb5f383679ea19912bcdc49c944973a' 'actions/checkout@v7.0.1'; do
    if has_dep "$FIX" "$k"; then bad "kept $k, which nothing reaches any more"; else ok "pruned $k"; fi
  done
  if has_dep "$FIX" "$RUST_CACHE"; then
    ok "kept Swatinem/rust-cache, still reached as swatinem/rust-cache"
  else
    bad "pruned Swatinem/rust-cache, which the standards record still reaches"
  fi
  d="$(dangling "$FIX")"
  if [ -z "$d" ]; then ok "no dangling edge"; else bad "dangling edge(s): $d"; fi
  cp "$FIX/.github/workflows/actions.lock" "$WORK/after-first"
  if deonboard "$ROOT/scripts" "$entry" "$FIX" >/dev/null 2>&1 && cmp -s "$WORK/after-first" "$FIX/.github/workflows/actions.lock"; then
    ok "a second run changes nothing"
  else
    bad "a second run changed the lock or failed"
  fi
done

echo "== both entry points give the same lock =="
if cmp -s "$WORK/fixed-wrapper/.github/workflows/actions.lock" "$WORK/fixed-generic/.github/workflows/actions.lock"; then
  ok "identical results"
else
  bad "the entry points disagree: $(diff "$WORK/fixed-wrapper/.github/workflows/actions.lock" "$WORK/fixed-generic/.github/workflows/actions.lock" | tr '\n' ' ')"
fi

echo "== a mutant with the byte-for-byte compare must fail through both entry points =="
MUT="$WORK/mutant/scripts"; mkdir -p "$MUT"
cp "$ROOT/scripts/deonboard-estate-audit.sh" "$MUT/"
sed 's/ | lower_repo//g' "$ROOT/scripts/deonboard-workflow.sh" > "$MUT/deonboard-workflow.sh"
chmod +x "$MUT/deonboard-estate-audit.sh" "$MUT/deonboard-workflow.sh"
if cmp -s "$ROOT/scripts/deonboard-workflow.sh" "$MUT/deonboard-workflow.sh"; then
  bad "mutant is identical to the script: the case-folding the test exists for is gone"
else
  for entry in wrapper generic; do
    MFIX="$WORK/mutated-$entry"; make_fixture "$MFIX"
    deonboard "$MUT" "$entry" "$MFIX" >/dev/null 2>&1 || true
    if has_dep "$MFIX" "$RUST_CACHE" && [ -z "$(dangling "$MFIX")" ]; then
      bad "mutant survived through the $entry entry point: the checks above do not detect the defect"
    else
      ok "mutant killed through the $entry entry point: it prunes Swatinem/rust-cache and leaves a dangling edge"
    fi
  done
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
