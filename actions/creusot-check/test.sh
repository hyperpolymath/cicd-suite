#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# test.sh — the Creusot gate must fail for each thing it claims to check,
# under the exact composite shell (bash --noprofile --norc -e -o pipefail).
#
# The prove phase is exercised against a stand-in `cargo-creusot` on PATH. The
# stub says "unproved" for any crate whose lib.rs contains the planted
# failing marker or a `// UNPROVED` line, and "proved" otherwise — which is
# exactly the contract the real tool must honour (exit code is the oracle).
# A second stub that can only say yes must make the gate refuse (exit 2).
# This does NOT prove Why3/SMT integration; the planted controls in check.sh
# do that at runtime, against the real tool, on every run.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="$here/check.sh"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
command -v cargo >/dev/null || { echo "cargo is required (it dispatches 'cargo creusot' to cargo-creusot on PATH)"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/out"
FIX="$WORK/fixture"

fresh_fixture() {
    rm -rf "$FIX"; mkdir -p "$FIX/src" "$FIX/docs"
    git -C "$FIX" init -q
    git -C "$FIX" config user.email t@example.invalid
    git -C "$FIX" config user.name t
    printf '[package]\nname = "fx"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\n' > "$FIX/Cargo.toml"
    printf '//! fixture\npub fn id(x: u32) -> u32 { x }\n' > "$FIX/src/lib.rs"
    printf '= fx\n\nA small crate.\n' > "$FIX/README.adoc"
    git -C "$FIX" add -A && git -C "$FIX" commit -qm fixture
}
commit() { git -C "$FIX" add -A && git -C "$FIX" commit -qm change >/dev/null; }
run_phase() { # <phase> [env...]
    ( cd "$FIX" && env CREUSOT_GATE_PHASE="$1" CREUSOT_FACTS="$WORK/facts" "${@:2}" \
        bash --noprofile --norc -e -o pipefail "$checker" ) > "$OUT" 2>&1
    RC=$?
}

echo "== a plain crate: no obligations, no claims, silent =="
fresh_fixture
run_phase detect
[ "$RC" -eq 0 ] && ok "detect exits 0" || { bad "detect exits $RC"; cat "$OUT"; }
grep -qx 'obligations=false' "$OUT" && ok "obligations=false" || bad "obligations misreported: $(cat "$OUT")"
grep -qx 'claims=false' "$OUT" && ok "claims=false" || bad "claims misreported"
run_phase theatre
[ "$RC" -eq 0 ] && ok "theatre exits 0" || bad "theatre exits $RC"
grep -q 'nothing claims to be' "$OUT" && ok "says it is silent, not green-as-assurance" || bad "no silence notice"
run_phase prove
[ "$RC" -eq 2 ] && ok "prove on a crate without obligations is exit 2 (no proof performed)" || bad "prove exits $RC, expected 2"

echo "== T1: a README claim with nothing behind it is a hard failure =="
printf '= fx\n\nThis crate is verified with Creusot.\n' > "$FIX/README.adoc"; commit
run_phase detect
grep -qx 'claims=true' "$OUT" && ok "detect sees the claim" || bad "claim not seen: $(cat "$OUT")"
run_phase theatre
[ "$RC" -eq 1 ] && ok "theatre exits 1" || bad "theatre exits $RC, expected 1"
grep -q '::error file=README.adoc,line=3::T1 Creusot theatre' "$OUT" && ok "annotates the claim at its line" || bad "T1 annotation missing: $(cat "$OUT")"

echo "== a roadmap sentence is not a claim =="
printf '= fx\n\nIt is planned to have this crate verified with Creusot.\n' > "$FIX/README.adoc"; commit
run_phase theatre
[ "$RC" -eq 0 ] && ok "planned work does not fire T1" || bad "a plan fired T1 (exit $RC)"

echo "== T2: a Creusot dependency with no contracts is hollow =="
printf '= fx\n\nA small crate.\n' > "$FIX/README.adoc"
printf '[package]\nname = "fx"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\ncreusot-std = "0.14"\n' > "$FIX/Cargo.toml"; commit
run_phase detect
grep -qx 'obligations=true' "$OUT" && ok "the dependency counts as an obligation" || bad "dependency not seen"
grep -qx 'creusot_version=0.14' "$OUT" && ok "reads the creusot-std version" || bad "version not read: $(cat "$OUT")"
run_phase theatre
[ "$RC" -eq 0 ] && ok "hollow is a warning by default" || bad "hollow failed by default (exit $RC)"
grep -q '::warning::T2 hollow' "$OUT" && ok "and is named" || bad "T2 warning missing"
run_phase theatre ENFORCE_HOLLOW=true
[ "$RC" -eq 1 ] && ok "hollow is a failure with ENFORCE_HOLLOW=true" || bad "ENFORCE_HOLLOW did not fail (exit $RC)"

echo "== contracts present: T2 silent, T3 lists trusted =="
cat > "$FIX/src/lib.rs" <<'RS'
//! fixture
use creusot_std::prelude::*;
#[ensures(result == x)]
pub fn id(x: u32) -> u32 { x }
#[trusted]
pub fn oracle() -> u32 { 7 }
RS
commit
run_phase detect
grep -qx 'contract_count=1' "$OUT" && ok "counts one contract" || bad "contract count wrong: $(cat "$OUT")"
grep -qx 'trusted_count=1' "$OUT" && ok "counts one trusted" || bad "trusted count wrong"
run_phase theatre ENFORCE_HOLLOW=true
[ "$RC" -eq 0 ] && ok "theatre exits 0 with a real contract" || bad "theatre exits $RC"
grep -q 'T3 residue: 1 #\[trusted\]' "$OUT" && ok "the trusted residue is listed" || bad "residue not listed"

echo "== prove: stub oracle that CAN say no =="
STAND_IN="$WORK/bin"; mkdir -p "$STAND_IN"
cat > "$STAND_IN/cargo-creusot" <<'SH'
#!/usr/bin/env bash
# v0.14 compiles/proves without a subcommand. A CLI parse error must not
# be mistaken for a rejected proof: reject the obsolete invocation here.
[ "${1:-}" = "creusot" ] || exit 64  # cargo supplies the plugin name
[ "${2:-}" != "--help" ] || exit 0
if [ "${2:-}" = "prove" ]; then
  echo "obsolete prove subcommand" >&2; exit 64
fi
if [ "${2:-}" = "init" ]; then
  # Stand-in only: real init copies the installed tool's configured template.
  printf '{"stand_in":true}\n' > why3find.json
  exit 0
fi
if [ -f Cargo.toml ] && grep -q 'name = "creusot-control-' Cargo.toml && [ ! -s why3find.json ]; then
  echo "missing control Why3find configuration" >&2; exit 65
fi
if grep -qE 'planted_must_fail|// UNPROVED' src/lib.rs 2>/dev/null; then
  echo "stub: 1 goal unproved"; exit 1
fi
echo "stub: all goals proved"; exit 0
SH
chmod +x "$STAND_IN/cargo-creusot"
run_phase prove PATH="$STAND_IN:$PATH"
[ "$RC" -eq 0 ] && ok "prove exits 0 when every crate proves" || { bad "prove exits $RC"; cat "$OUT"; }
grep -q 'false contract refused' "$OUT" && ok "planted failing control was exercised" || bad "failing control not run"
grep -q 'true contract proved' "$OUT" && ok "planted passing control was exercised" || bad "passing control not run"
echo "== obsolete CLI mutation must not produce a proof verdict =="
original_checker="$checker"
sed 's/cargo creusot \$prove_args/cargo creusot prove $prove_args/g' "$checker" > "$WORK/obsolete-check.sh"
checker="$WORK/obsolete-check.sh"
run_phase prove PATH="$STAND_IN:$PATH"
[ "$RC" -eq 2 ] && ok "obsolete subcommand is NOT RUN, never proof success" || bad "obsolete CLI exited $RC"
grep -q 'obsolete prove subcommand' "$OUT" && ok "strict v0.14 oracle rejected the obsolete CLI" || bad "CLI mutant was not exercised"
checker="$original_checker"
echo "== control initialisation must supply configuration =="
sed '/printf.*stand_in.*why3find.json/d' "$STAND_IN/cargo-creusot" > "$WORK/no-config-oracle"
cp "$STAND_IN/cargo-creusot" "$WORK/good-oracle"
cp "$WORK/no-config-oracle" "$STAND_IN/cargo-creusot"
run_phase prove PATH="$STAND_IN:$PATH"
[ "$RC" -eq 2 ] && ok "missing control configuration is NOT RUN" || bad "missing configuration exited $RC"
grep -q 'control initialisation did not supply why3find.json' "$OUT" && ok "names the actual setup failure" || bad "configuration failure not explained"
cp "$WORK/good-oracle" "$STAND_IN/cargo-creusot"
printf '// UNPROVED\n' >> "$FIX/src/lib.rs"; commit
run_phase prove PATH="$STAND_IN:$PATH"
[ "$RC" -eq 1 ] && ok "an unproved crate fails the gate" || bad "unproved crate exits $RC, expected 1"
grep -q "::error file=./Cargo.toml::creusot-check\[prove\]" "$OUT" && ok "the failing crate is annotated" || bad "crate not annotated: $(cat "$OUT")"

echo "== prove: an oracle that can only say yes makes the verdict VOID =="
cat > "$STAND_IN/cargo-creusot" <<'SH'
#!/usr/bin/env bash
# Initialise normally, but lie about every proof, including the false control.
if [ "${2:-}" = "init" ]; then
  printf '{"stand_in":true}\n' > why3find.json
fi
echo yes; exit 0
SH
run_phase prove PATH="$STAND_IN:$PATH"
[ "$RC" -eq 2 ] && ok "exits 2 (NO PROOF WAS PERFORMED)" || bad "exits $RC, expected 2"
grep -q 'cannot fail' "$OUT" && ok "says the prover cannot fail" || bad "no explanation"

echo "== prove: no cargo creusot at all is exit 2 =="
rm -f "$STAND_IN/cargo-creusot"
run_phase prove PATH="$STAND_IN:/usr/bin:/bin"
[ "$RC" -eq 2 ] && ok "exits 2 without the tool" || bad "exits $RC without the tool, expected 2"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
