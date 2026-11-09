#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# test.sh — the PRAT gate must be able to fail for each thing it claims to
# check, under the composite shell semantics, and must not pass when idris2
# is absent. The binary is built ONCE here and reused across fixtures via
# PRAT_CHECK_BIN (consumers never set that; it exists for this suite).
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
cp -R "$here/src" "$here/prat-check.ipkg" "$BUILD/"
if ! (cd "$BUILD" && idris2 --build prat-check.ipkg) > "$WORK/build.log" 2>&1; then
  cat "$WORK/build.log" >&2
  echo "FAIL: checker does not compile" >&2
  exit 1
fi
export PRAT_CHECK_BIN="$BUILD/build/exec/prat-check"

mkfix() { rm -rf "$FIX"; mkdir -p "$FIX"; }

run_gate() { # <workdir> [REQUIRE_PROPERTIES=…] [RUN_TESTS=…] [PATH=…]
  local dir="$1"; shift
  ( cd "$FIX" && env "$@" WORKING_DIRECTORY=. GITHUB_OUTPUT="$WORK/ghout" \
      bash --noprofile --norc -e -o pipefail "$checker" ) > "$WORK/out" 2>&1
  RC=$?
  STATUS="$(sed -n 's/^status=//p' "$WORK/ghout" 2>/dev/null | tail -1)"
  : > "$WORK/ghout"
}

assert_fail() { # <label> <grep>
  if [ "$RC" -eq 1 ] && grep -qiE "$2" "$WORK/out"; then ok "$1"; else bad "$1 (rc=$RC)"; sed 's/^/      /' "$WORK/out"; fi
}
assert_pass() { # <label>
  if [ "$RC" -eq 0 ]; then ok "$1"; else bad "$1 (rc=$RC)"; sed 's/^/      /' "$WORK/out"; fi
}

# --- 1. declared framework, no properties written -> FAIL ------------------
mkfix; mkdir -p "$FIX/src"
cat > "$FIX/Cargo.toml" <<'T'
[package]
name = "demo"
version = "0.1.0"
edition = "2021"
[dependencies]
proptest = "1"
T
printf 'fn main() { println!("hi"); }\n' > "$FIX/src/main.rs"
run_gate "$FIX"
assert_fail "declared proptest with zero properties fails" 'proptest'

# --- 2. declared framework + property tests -> PASS -------------------------
mkfix; mkdir -p "$FIX/tests"
printf '[package]\nname = "demo"\n[dependencies]\nproptest = "1"\n' > "$FIX/Cargo.toml"
cat > "$FIX/tests/prop.rs" <<'T'
use proptest::prelude::*;
proptest! {
    #[test]
    fn pop_push(xs: Vec<i32>) { prop_assert_eq!(xs.len() + 1, xs.len() + 1); }
}
T
run_gate "$FIX"
assert_pass "declared proptest with properties passes"

# --- 3. completely empty repo, default policy -> FAIL ------------------------
mkfix
run_gate "$FIX"
assert_fail "no PBT evidence anywhere fails by default" 'no property-based testing'

# --- 4. same repo, require_properties=false -> PASS (advisory) ---------------
mkfix
run_gate "$FIX" REQUIRE_PROPERTIES=false
assert_pass "require_properties=false demotes absence to a notice"

# --- 5. marker without declaration (Go stdlib quick) -> PASS -----------------
mkfix
cat > "$FIX/main_test.go" <<'T'
package demo
import (
    "testing"
    "testing/quick"
)
func BenchmarkAdd(f *testing.F) { _ = f }
func TestAdd(t *testing.T) {
    f := func(a, b int) bool { return a + b == b + a }
    if err := quick.Check(f, nil); err != nil { t.Fatal(err) }
}
T
run_gate "$FIX"
assert_pass "stdlib quick.Check marker counts as evidence"

# --- 6. Python @property is NOT property-based testing ------------------------
mkfix
cat > "$FIX/model.py" <<'T'
class Model:
    @property
    def name(self):
        return self._name
T
cat > "$FIX/pyproject.toml" <<'T'
[project]
name = "demo"
T
run_gate "$FIX"
assert_fail "python @property is not jqwik (scoping works)" 'no property-based testing'

# --- 7. Haskell forAll in .hs counts -> PASS ----------------------------------
mkfix
printf -- '- QuickCheck\n  cabal: quickcheck >= 2.14\n' > "$FIX/stack.yaml"
cat > "$FIX/Spec.hs" <<'T'
import Test.QuickCheck
prop_rev :: [Int] -> Bool
prop_rev xs = reverse (reverse xs) == xs
main = quickCheck prop_rev
T
run_gate "$FIX"
assert_pass "haskell quickcheck declared + forAll/prop_ markers passes"

# --- 8. status output is written ----------------------------------------------
mkfix; mkdir -p "$FIX/tests"
printf '[package]\nname = "demo"\n[dependencies]\nproptest = "1"\n' > "$FIX/Cargo.toml"
printf 'proptest! { #[test] fn x(n: u8) { prop_assert!(n == n); } }\n' > "$FIX/tests/p.rs"
run_gate "$FIX"
[ "$RC" -eq 0 ] && [ "$STATUS" = "passed" ] && ok "status=passed written to GITHUB_OUTPUT" \
                                               || bad "status output wrong (rc=$RC status=$STATUS)"

# --- 9. multi-ecosystem declared, none with properties -> FAIL naming both ----
mkfix
printf '[package]\nname = "demo"\n[dependencies]\nproptest = "1"\n' > "$FIX/Cargo.toml"
printf '[project]\nname = "demo"\n[tool.poetry.dependencies]\npython = "^3.11"\nhypothesis = "^6"\n' > "$FIX/pyproject.toml"
printf 'print("no properties here")\n' > "$FIX/main.py"
run_gate "$FIX"
assert_fail "rust+python declared, zero properties written" 'proptest|pyproject'

# --- 10. tool absence: no idris2 on PATH -> not_run, no success line ----------
mkfix
NOBIN="$WORK/nobin"; mkdir -p "$NOBIN"
for t in bash env tr sed cat grep cp mktemp mkdir rm timeout sleep dirname basename uname; do
  ln -sf "$(command -v "$t")" "$NOBIN/$t"
done
( cd "$FIX" && env -i PATH="$NOBIN" GITHUB_OUTPUT="$WORK/ghout2" \
    bash --noprofile --norc -e -o pipefail "$checker" ) > "$WORK/out2" 2>&1
RC2=$?
STATUS2="$(sed -n 's/^status=//p' "$WORK/ghout2" 2>/dev/null | tail -1)"
if [ "$RC2" -eq 2 ] && [ "$STATUS2" = "not_run" ] \
   && ! grep -qiE 'passed|PRAT testing vectors detected' "$WORK/out2"; then
  ok "absent idris2 → exit 2, status=not_run, no success line"
else
  bad "tool-absence contract broken (rc=$RC2 status=$STATUS2)"; sed 's/^/      /' "$WORK/out2"
fi

# --- 11. run_tests with a runner that fails -> defect, exit 1 -----------------
mkfix; mkdir -p "$FIX/tests"
printf '[package]\nname = "demo"\n[dependencies]\nproptest = "1"\n' > "$FIX/Cargo.toml"
printf 'proptest! { #[test] fn x(n: u8) { prop_assert!(n == n); } }\n' > "$FIX/tests/p.rs"
FAKEPATH="$WORK/fakebin"; mkdir -p "$FAKEPATH"
cat > "$FAKEPATH/cargo" <<'T'
#!/bin/sh
exit 1
T
chmod +x "$FAKEPATH/cargo"
for t in bash env tr sed cat grep mktemp mkdir rm timeout dirname basename uname readlink; do
  ln -sf "$(command -v "$t")" "$FAKEPATH/$t"
done
( cd "$FIX" && env PATH="$FAKEPATH" PRAT_CHECK_BIN="$PRAT_CHECK_BIN" \
    WORKING_DIRECTORY=. RUN_TESTS=true GITHUB_OUTPUT="$WORK/ghout3" \
    bash --noprofile --norc -e -o pipefail "$checker" ) > "$WORK/out3" 2>&1
RC3=$?
if [ "$RC3" -eq 1 ] && grep -qi 'test command failed' "$WORK/out3"; then
  ok "failing test suite reported as a defect"
else
  bad "run_tests failure contract broken (rc=$RC3)"; sed 's/^/      /' "$WORK/out3"
fi

# --- 12. run_tests with runner missing -> not_run, exit 2 ----------------------
mkfix; mkdir -p "$FIX/tests"
printf '[package]\nname = "demo"\n[dependencies]\nproptest = "1"\n' > "$FIX/Cargo.toml"
printf 'proptest! { #[test] fn x(n: u8) { prop_assert!(n == n); } }\n' > "$FIX/tests/p.rs"
EMPTYPATH="$WORK/emptybin"; mkdir -p "$EMPTYPATH"
for t in bash env tr sed cat grep mktemp mkdir rm timeout dirname basename uname readlink; do
  ln -sf "$(command -v "$t")" "$EMPTYPATH/$t"
done
( cd "$FIX" && env PATH="$EMPTYPATH" PRAT_CHECK_BIN="$PRAT_CHECK_BIN" \
    WORKING_DIRECTORY=. RUN_TESTS=true GITHUB_OUTPUT="$WORK/ghout4" \
    bash --noprofile --norc -e -o pipefail "$checker" ) > "$WORK/out4" 2>&1
RC4=$?
STATUS4="$(sed -n 's/^status=//p' "$WORK/ghout4" 2>/dev/null | tail -1)"
if [ "$RC4" -eq 2 ] && [ "$STATUS4" = "not_run" ]; then
  ok "missing runner → exit 2, status=not_run"
else
  bad "run_tests not_run contract broken (rc=$RC4 status=$STATUS4)"; sed 's/^/      /' "$WORK/out4"
fi

echo
echo "prat-check tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
