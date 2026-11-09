#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# test.sh — the semantic-audit gate must be able to fail for each check it
# claims, under the composite shell semantics, must report not_applicable
# honestly (never a pass by absence), and must not pass when idris2 is
# absent. The binary is built ONCE here via SEMANTIC_AUDIT_CHECK_BIN.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="$here/check.sh"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

command -v idris2 >/dev/null || { echo "idris2 is required for this suite (bootstrap pin: docs/assurance/SUITE-CLOSEOUT.adoc)"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/fixture"

echo "== building the checker once =="
BUILD="$WORK/build"; mkdir -p "$BUILD"
cp -R "$here/src" "$here/semantic-audit-check.ipkg" "$BUILD/"
if ! (cd "$BUILD" && idris2 --build semantic-audit-check.ipkg) > "$WORK/build.log" 2>&1; then
  cat "$WORK/build.log" >&2
  echo "FAIL: checker does not compile" >&2
  exit 1
fi
export SEMANTIC_AUDIT_CHECK_BIN="$BUILD/build/exec/semantic-audit-check"

mkfix() { rm -rf "$FIX"; mkdir -p "$FIX"; }
desc()  { mkdir -p "$FIX/.machine_readable/descriptiles"; }
state()  { printf '[state]\nphase = "in_progress"\nupdated = "2026-11-01"\n' > "$FIX/.machine_readable/descriptiles/STATE.a2ml"; }
meta()   { printf '[meta]\nname = "demo"\npurpose = "fixture with real governance meaning attached"\n' > "$FIX/.machine_readable/descriptiles/META.a2ml"; }
ecosystem() { printf '[ecosystem]\nupstream = "standards"\n' > "$FIX/.machine_readable/descriptiles/ECOSYSTEM.a2ml"; }
good_triple() { state; meta; ecosystem; }

run_gate() { # [ENV=…]
  ( cd "$FIX" && env "$@" WORKING_DIRECTORY=. GITHUB_OUTPUT="$WORK/ghout" \
      bash --noprofile --norc -e -o pipefail "$checker" ) > "$WORK/out" 2>&1
  RC=$?
  STATUS="$(sed -n 's/^status=//p' "$WORK/ghout" 2>/dev/null | tail -1)"
  : > "$WORK/ghout"
}
assert_fail() { if [ "$RC" -eq 1 ] && grep -qiE "$2" "$WORK/out"; then ok "$1"; else bad "$1 (rc=$RC)"; sed 's/^/      /' "$WORK/out"; fi; }
assert_pass() { if [ "$RC" -eq 0 ]; then ok "$1"; else bad "$1 (rc=$RC)"; sed 's/^/      /' "$WORK/out"; fi; }

# --- 1. empty repo -> not_applicable, exit 0, no "Passed." gloating -----------
mkfix
run_gate
[ "$RC" -eq 0 ] && [ "$STATUS" = "not_applicable" ] && ok "empty repo → not_applicable, not a pass" \
                                                    || bad "not_applicable contract broken (rc=$RC status=$STATUS)"

# --- 2. core set missing (only STATE present) -> FAIL naming both missing ------
mkfix; desc; state
run_gate
if [ "$RC" -eq 1 ] && grep -qi 'META\.a2ml' "$WORK/out" && grep -qi 'ECOSYSTEM\.a2ml' "$WORK/out"; then
  ok "missing META and ECOSYSTEM descriptiles fail"
else
  bad "missing META and ECOSYSTEM descriptiles fail (rc=$RC)"; sed 's/^/      /' "$WORK/out"
fi

# --- 3. empty core descriptile -> FAIL ------------------------------------------
mkfix; desc; state; printf '# only a comment\n' > "$FIX/.machine_readable/descriptiles/META.a2ml"; ecosystem
run_gate
assert_fail "comments-only descriptile fails" 'empty|META\.a2ml'

# --- 4. the good minimal fixture -> PASS -----------------------------------------
mkfix; desc; good_triple
run_gate
assert_pass "STATE+META+ECOSYSTEM, non-empty → passed"

# --- 5. allow/ban contradiction across files -> FAIL ------------------------------
mkfix; desc; good_triple
cat > "$FIX/.machine_readable/descriptiles/AGENTIC.a2ml" <<'T'
[constraints]
languages = ["rust", "python", "zig"]
T
cat >> "$FIX/.machine_readable/descriptiles/META.a2ml" <<'T'
banned = ["python", "ruby"]
T
run_gate
assert_fail "token allowed in one file, banned in another fails" "contradictory policy.*python"

# --- 6. verbatim policy restatement across files -> FAIL --------------------------
mkfix; desc; good_triple
shared='banned = ["typescript", "go", "python", "makefile", "ruby"] # permanent estate-wide ban list'
printf '[state]\nphase = "in_progress"\n%s\n' "$shared" > "$FIX/.machine_readable/descriptiles/STATE.a2ml"
printf '[meta]\nname = "demo"\n%s\n' "$shared" > "$FIX/.machine_readable/descriptiles/META.a2ml"
run_gate
assert_fail "policy line restated verbatim across files fails" 'restated verbatim'

# --- 7. K9 contract missing required v1.0.0 fields -> FAIL -------------------------
mkfix; desc; good_triple; mkdir -p "$FIX/.machine_readable/contractiles/must"
cat > "$FIX/.machine_readable/contractiles/must/must.k9.ncl" <<'T'
{
  schema_version = "1.0.0",
}
T
run_gate
assert_fail "K9 contract missing fields fails" 'missing required field'

# --- 8. K9 contract complete -> PASS ----------------------------------------------
mkfix; desc; good_triple; mkdir -p "$FIX/.machine_readable/contractiles/must"
cat > "$FIX/.machine_readable/contractiles/must/must.k9.ncl" <<'T'
{
  schema_version = "1.0.0",
  component_type = "contractile:must",
  semantics = "invariant assertion",
  security = { leash = "Kennel", trust_level = "internal" },
  side_effects = { network = "deny", filesystem_write = "deny" },
}
T
run_gate
assert_pass "complete K9 contract passes"

# --- 9. coordination.k9 is routed, never field-failed -------------------------------
mkfix; desc; good_triple; mkdir -p "$FIX/.machine_readable"
printf '{ schema_version = "1.0.0" }\n' > "$FIX/.machine_readable/coordination.k9"
run_gate
assert_pass "coordination.k9 routed with only routing notice"

# --- 10. CLAUDE.md defects: empty, no H1, merge markers, fences, placeholders ------
mkfix; desc; good_triple
printf '   \n# only a comment? no, an actual empty doc\n' > "$FIX/CLAUDE.md"
printf '' > "$FIX/CLAUDE.md"
run_gate
assert_fail "empty CLAUDE.md fails" 'empty'

mkfix; desc; good_triple
printf 'Just prose, no heading.\n' > "$FIX/CLAUDE.md"
run_gate
assert_fail "CLAUDE.md without H1 fails" 'top-level heading'

mkfix; desc; good_triple
printf '# Guide\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> branch\n' > "$FIX/CLAUDE.md"
run_gate
assert_fail "merge markers fail" 'merge-conflict'

mkfix; desc; good_triple
printf '# Guide\n\n```sh\necho one\n' > "$FIX/CLAUDE.md"
run_gate
assert_fail "unbalanced code fence fails" 'unbalanced'

mkfix; desc; good_triple
printf '# Guide\n\nRepo: {{REPO_NAME}}\n' > "$FIX/CLAUDE.md"
run_gate
assert_fail "unresolved template placeholder fails" 'template placeholder'

mkfix; desc; good_triple
printf '# Guide\n\nReal content for real agents.\n' > "$FIX/CLAUDE.md"
run_gate
assert_pass "well-formed CLAUDE.md passes"

# --- 11. bot_directives presence reported, never judged ------------------------------
mkfix; desc; good_triple; mkdir -p "$FIX/.machine_readable/bot_directives"
printf ';; bot rules\n(do-not-delete)\n' > "$FIX/.machine_readable/bot_directives/root-hygiene.scm"
run_gate
assert_pass "bot_directives present: noticed, not failed"
grep -qi 'bot_directives' "$WORK/out" || bad "bot_directives not even reported"

# --- 12. legacy .a2ml contractiles warn but do not fail -------------------------------
mkfix; desc; good_triple; mkdir -p "$FIX/.machine_readable/contractiles/must"
printf '[must]\n' > "$FIX/.machine_readable/contractiles/must/Mustfile.a2ml"
run_gate
assert_pass "legacy .a2ml declaration warns without failing"

# --- 13. tool absence: no idris2 on PATH -> not_run, no success line ------------------
mkfix; desc; good_triple
NOBIN="$WORK/nobin"; mkdir -p "$NOBIN"
for t in bash env tr sed cat grep cp mktemp mkdir rm timeout sleep dirname basename uname; do
  ln -sf "$(command -v "$t")" "$NOBIN/$t"
done
( cd "$FIX" && env -i PATH="$NOBIN" GITHUB_OUTPUT="$WORK/ghout2" \
    bash --noprofile --norc -e -o pipefail "$checker" ) > "$WORK/out2" 2>&1
RC2=$?
STATUS2="$(sed -n 's/^status=//p' "$WORK/ghout2" 2>/dev/null | tail -1)"
if [ "$RC2" -eq 2 ] && [ "$STATUS2" = "not_run" ] \
   && ! grep -qiE 'Semantic Audit Passed|passed\.$' "$WORK/out2"; then
  ok "absent idris2 → exit 2, status=not_run, no success line"
else
  bad "tool-absence contract broken (rc=$RC2 status=$STATUS2)"; sed 's/^/      /' "$WORK/out2"
fi

# --- 14. status output mapping on failure ----------------------------------------------
mkfix; desc; state
run_gate
[ "$RC" -eq 1 ] && [ "$STATUS" = "failed" ] && ok "status=failed written to GITHUB_OUTPUT" \
                                                || bad "status=failed mapping broken (rc=$RC status=$STATUS)"

# --- 15. surface (s-expression) is reported, not failed ---------------------------------
mkfix; desc
printf '(state (metadata (version "1.0")))\n' > "$FIX/.machine_readable/descriptiles/STATE.a2ml"
meta; ecosystem
run_gate
assert_pass "s-expression surface warns without failing"

echo
echo "semantic-audit-check tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
