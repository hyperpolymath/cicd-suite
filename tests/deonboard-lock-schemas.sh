#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# scripts/deonboard-estate-audit.sh against every actions.lock schema it
# claims to support.
#
# The de-onboard script edits a lockfile that gh-actions-lock owns. When
# gh-actions-lock moved from schema v0.0.2 to v0.0.3 (v0.2.0, "Upgraded
# lockfile schema v0.0.2 → v0.0.3"), nothing but a hand check showed the script
# still worked. This test makes that check permanent:
#
#   * the script fails closed (exit 3) on any schema not in its
#     `known_versions` list, so a future schema is a loud error, not a silent
#     corruption of 199 lockfiles;
#   * every version in that list must have a fixture here, so the list cannot
#     grow without a test;
#   * every fixture is de-onboarded, and the result must be pure removals with
#     the same version line, closed (every reference resolves), orphan-free,
#     and idempotent;
#   * all fixtures are the same lock in different schemas, so all must prune
#     the same dependency keys.
#
# The fixtures were also parsed, before and after, by the canonical parser
# (github.com/github/actions-lockfile/go v0.0.6, the one gh-actions-lock v0.2.0
# uses). That parser rejects unknown fields and future versions, so it is the
# authority on validity; this test checks the structural properties above
# without needing Go in CI.
#
# Two negative controls keep the test honest: an unknown schema must be
# refused with the lock untouched, and a mutant script that skips the prune
# must FAIL the orphan check.
#
# Usage: deonboard-lock-schemas.sh [script]   (a path lets the mutant run)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${1:-$ROOT/scripts/deonboard-estate-audit.sh}"
FIXTURES="$ROOT/tests/fixtures/actions-lock"
WF=".github/workflows/main-estate-audit.yml"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

yq --version 2>/dev/null | grep -q mikefarah || { echo "mikefarah yq v4 is required"; exit 2; }
[ -f "$SCRIPT" ] || { echo "no script at $SCRIPT"; exit 2; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# A throwaway repo holding <fixture> as its actions.lock; prints the repo dir.
stage() { # <fixture> <name>
  local r="$work/$2"
  rm -rf "$r"; mkdir -p "$r/.github/workflows"
  cp "$1" "$r/.github/workflows/actions.lock"
  printf '%s\n' "$r"
}

# References that do not resolve to a dependency key (expect none).
dangling() { # <lock>
  { yq '.workflows[][]' "$1"
    yq '.dependencies[] | select(has("uses")) | .uses[]' "$1"
  } | sort -u | grep -vxF -f <(yq '.dependencies | keys | .[]' "$1") || true
}

# Dependency keys nothing references (expect none).
orphans() { # <lock>
  yq '.dependencies | keys | .[]' "$1" \
    | grep -vxF -f <({ yq '.workflows[][]' "$1"
                       yq '.dependencies[] | select(has("uses")) | .uses[]' "$1"
                     } | sort -u) || true
}

# Newline-separated list to one line, for messages.
oneline() { tr "\n" " " <<<"$1" | sed "s/ $//"; }

removed_keys() { # <before> <after>
  comm -23 <(yq '.dependencies | keys | .[]' "$1" | sort) \
           <(yq '.dependencies | keys | .[]' "$2" | sort)
}

echo "== every supported schema has a fixture"
known=$(sed -n 's/^known_versions="\(.*\)"$/\1/p' "$SCRIPT")
[ -n "$known" ] && ok "script declares known_versions: $known" || bad "script declares no known_versions"
for v in $known; do
  [ -f "$FIXTURES/$v.lock" ] && ok "fixture for $v" || bad "no fixture $FIXTURES/$v.lock for supported schema $v"
done

reference=""
for fx in "$FIXTURES"/*.lock; do
  name=$(basename "$fx" .lock)
  echo "== $name"
  before_ver=$(yq '.version' "$fx")
  w="$WF" yq -e '.workflows | has(strenv(w))' "$fx" >/dev/null \
    && ok "fixture onboards $WF" || bad "fixture does not onboard $WF, so it tests nothing"

  r=$(stage "$fx" "$name")
  lock="$r/.github/workflows/actions.lock"
  if out=$(bash "$SCRIPT" "$r" 2>&1); then ok "script exits 0"; else bad "script failed: $out"; continue; fi

  w="$WF" yq -e '.workflows | has(strenv(w)) | not' "$lock" >/dev/null \
    && ok "$WF entry removed" || bad "$WF entry still present"
  [ "$(yq '.version' "$lock")" = "$before_ver" ] \
    && ok "version line kept ($before_ver)" || bad "version changed to $(yq '.version' "$lock")"
  added=$(diff "$fx" "$lock" | grep -c '^>' || true)
  [ "$added" -eq 0 ] && ok "pure removals" || bad "$added line(s) added or rewritten"
  d=$(dangling "$lock"); [ -z "$d" ] && ok "every reference resolves" || bad "dangling: $d"
  o=$(orphans "$lock");  [ -z "$o" ] && ok "no orphaned dependencies" || bad "orphaned: $o"

  cp "$lock" "$work/once"
  bash "$SCRIPT" "$r" >/dev/null 2>&1
  cmp -s "$work/once" "$lock" && ok "idempotent" || bad "second run changed the lock"

  keys=$(removed_keys "$fx" "$lock")
  if [ -z "$reference" ]; then
    reference="$keys"
    [ -n "$keys" ] && ok "pruned: $(oneline "$keys")" || bad "pruned nothing"
  else
    [ "$keys" = "$reference" ] && ok "same keys pruned as the first fixture" \
      || bad "pruned set differs: $(oneline "$keys")"
  fi
done

echo "== negative control: an untested schema is refused, lock untouched"
r=$(stage "$FIXTURES/v0.0.2.lock" future)
lock="$r/.github/workflows/actions.lock"
sed -i "s/^version: 'v0\.0\.2'$/version: 'v9.9.9'/" "$lock"
cp "$lock" "$work/future-before"
bash "$SCRIPT" "$r" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && ok "exit 3 on schema v9.9.9" || bad "exit $rc on schema v9.9.9 (want 3)"
cmp -s "$work/future-before" "$lock" && ok "lock untouched" || bad "lock modified despite refusal"

echo "== negative control: a mutant that skips the prune fails the orphan check"
if [ "$SCRIPT" = "$ROOT/scripts/deonboard-estate-audit.sh" ]; then
  mutant="$work/mutant.sh"
  sed 's/^  \[ -n "\$unused" \] || break$/  break/' "$SCRIPT" > "$mutant"
  if cmp -s "$SCRIPT" "$mutant"; then
    bad "mutation did not apply; the prune loop changed shape, update this control"
  else
    r=$(stage "$FIXTURES/v0.0.3.lock" mutant)
    bash "$mutant" "$r" >/dev/null 2>&1
    o=$(orphans "$r/.github/workflows/actions.lock")
    [ -n "$o" ] && ok "mutant leaves orphans, and the check sees them: $(oneline "$o")" \
      || bad "orphan check passed a mutant that does not prune"
  fi
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
