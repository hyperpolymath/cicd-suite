#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# test.sh — the Rust gate must be able to FAIL, for each thing it claims to
# check, under the exact shell GitHub gives a composite step
# (bash --noprofile --norc -e -o pipefail). A gate suite that only goes green
# proves nothing (tests/composite-shell-contract.sh explains the -e trap).
#
# Needs a working cargo (ubuntu runners carry rustup stable). Everything runs
# in a throwaway fixture crate with no dependencies, so no network is used.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="$here/check.sh"
resolver="$here/resolve.sh"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

command -v cargo >/dev/null || { echo "cargo is required to test the Rust gate"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/fixture"
mkdir -p "$FIX/src"
cat > "$FIX/Cargo.toml" <<'TOML'
[package]
name = "gate-fixture"
version = "0.1.0"
edition = "2021"
rust-version = "1.74"

[dependencies]
TOML
cat > "$FIX/src/lib.rs" <<'RS'
//! Fixture crate for the Rust gate self-test.

/// Adds two numbers.
///
/// ```
/// assert_eq!(gate_fixture::add(2, 2), 4);
/// ```
pub fn add(a: u32, b: u32) -> u32 {
    a + b
}

#[cfg(test)]
mod tests {
    #[test]
    fn adds() {
        assert_eq!(super::add(1, 1), 2);
    }
}
RS
(cd "$FIX" && cargo generate-lockfile --quiet 2>/dev/null) || { echo "cannot generate a lockfile for the fixture"; exit 2; }
# cargo fmt needs rustfmt; clippy needs clippy. Say so rather than fake a pass.
(cd "$FIX" && cargo fmt --version >/dev/null 2>&1) || { echo "rustfmt is required (rustup component add rustfmt)"; exit 2; }
(cd "$FIX" && cargo clippy --version >/dev/null 2>&1) || { echo "clippy is required (rustup component add clippy)"; exit 2; }

# Run a phase under the exact CI shell; result lands in $OUT / $RC.
OUT="$WORK/out"
run_phase() { # <phase> [env assignments...]
    local phase="$1"; shift
    ( cd "$FIX" && env RUST_GATE_PHASE="$phase" CARGO_TERM_COLOR=never "$@" \
        bash --noprofile --norc -e -o pipefail "$checker" ) > "$OUT" 2>&1
    RC=$?
}
run_resolve() { ( cd "$FIX" && env "$@" bash --noprofile --norc -e -o pipefail "$resolver" ) > "$OUT" 2>&1; RC=$?; }

echo "== resolve.sh on the fixture =="
run_resolve WORKING_DIRECTORY=.
[ "$RC" -eq 0 ] && ok "exits 0" || { bad "exits $RC"; cat "$OUT"; }
grep -qx 'toolchain=stable' "$OUT"        && ok "defaults the toolchain to stable" || bad "no default toolchain: $(cat "$OUT")"
grep -qx 'toolchain_source=default' "$OUT" && ok "names the source as default" || bad "source not named"
grep -qx 'msrv=1.74' "$OUT"               && ok "reads rust-version 1.74" || bad "msrv not read"
grep -qx 'has_lock=true' "$OUT"           && ok "sees Cargo.lock" || bad "lock not seen"

echo "== resolve.sh honours rust-toolchain.toml =="
printf '[toolchain]\nchannel = "nightly-2026-08-03"\ncomponents = ["rustfmt"]\n' > "$FIX/rust-toolchain.toml"
run_resolve WORKING_DIRECTORY=.
grep -qx 'toolchain=nightly-2026-08-03' "$OUT" && ok "reads the channel from the file" || bad "channel not read: $(cat "$OUT")"
run_resolve WORKING_DIRECTORY=. TOOLCHAIN=1.85.0
grep -qx 'toolchain=1.85.0' "$OUT" && ok "an explicit input wins" || bad "input did not win"
grep -q '::warning' "$OUT" && ok "and the disagreement is a visible warning" || bad "silent override"

echo "== resolve.sh REFUSES an empty toolchain (the estate failure class) =="
printf '[toolchain]\n# channel deliberately missing\n' > "$FIX/rust-toolchain.toml"
run_resolve WORKING_DIRECTORY=.
[ "$RC" -eq 1 ] && ok "exits 1 on a toolchain file that names nothing" || bad "exits $RC, expected 1"
grep -q "resolved toolchain is EMPTY" "$OUT" && ok "says why, naming the required-input failure" || bad "no explanation"
rm -f "$FIX/rust-toolchain.toml"

echo "== check phase on a clean crate =="
run_phase check
[ "$RC" -eq 0 ] && ok "check phase exits 0" || { bad "check phase exits $RC"; tail -20 "$OUT"; }
grep -q 'ok: cargo fmt' "$OUT" && ok "runs cargo fmt" || bad "fmt not run"
grep -q 'ok: cargo clippy' "$OUT" && ok "runs cargo clippy" || bad "clippy not run"

echo "== check phase fails on a formatting defect, naming fmt =="
cp "$FIX/src/lib.rs" "$WORK/lib.rs.good"
printf '\n\n\nfn   ugly( ) {   }\n' >> "$FIX/src/lib.rs"
run_phase check
[ "$RC" -eq 1 ] && ok "exits 1" || bad "exits $RC, expected 1"
grep -q 'cargo fmt failed' "$OUT" && ok "annotates the fmt failure" || bad "fmt failure not annotated"
cp "$WORK/lib.rs.good" "$FIX/src/lib.rs"

echo "== check phase fails on a clippy warning (-D warnings) =="
printf '\npub fn shadow() -> bool { let x = true; if x == true { x } else { false } }\n' >> "$FIX/src/lib.rs"
run_phase check
[ "$RC" -eq 1 ] && ok "exits 1 on bool_comparison" || bad "exits $RC, expected 1"
grep -q 'cargo clippy failed' "$OUT" && ok "annotates the clippy failure" || bad "clippy failure not annotated"
cp "$WORK/lib.rs.good" "$FIX/src/lib.rs"

echo "== test phase runs doctests (the hole --all-targets leaves) =="
run_phase test
[ "$RC" -eq 0 ] && ok "test phase exits 0 on a clean crate" || { bad "test phase exits $RC"; tail -20 "$OUT"; }
grep -q 'ok: cargo doctests' "$OUT" && ok "doctests ran" || bad "doctests did not run"
sed -i 's/assert_eq!(gate_fixture::add(2, 2), 4);/assert_eq!(gate_fixture::add(2, 2), 5);/' "$FIX/src/lib.rs"
run_phase test
[ "$RC" -eq 1 ] && ok "a broken /// example FAILS the gate" || bad "broken doctest passed (exit $RC) — the old gate's hole is still open"
grep -q 'cargo doctests failed' "$OUT" && ok "and is annotated as a doctest failure" || bad "doctest failure not annotated"
cp "$WORK/lib.rs.good" "$FIX/src/lib.rs"

echo "== test phase: a bin-only workspace reports 'no doctests', not a failure =="
BIN="$WORK/binonly"; mkdir -p "$BIN/src"
printf '[package]\nname = "binonly"\nversion = "0.1.0"\nedition = "2021"\n' > "$BIN/Cargo.toml"
printf 'fn main() {}\n' > "$BIN/src/main.rs"
(cd "$BIN" && cargo generate-lockfile --quiet 2>/dev/null)
( cd "$BIN" && env RUST_GATE_PHASE=test CARGO_TERM_COLOR=never bash --noprofile --norc -e -o pipefail "$checker" ) > "$OUT" 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "exits 0" || { bad "exits $RC"; tail -5 "$OUT"; }
grep -q '::notice::.*no library target' "$OUT" && ok "says there were no doctests, as a notice" || bad "the no-library case is not reported"

echo "== doc phase denies warnings =="
run_phase doc
[ "$RC" -eq 0 ] && ok "doc phase exits 0 on clean docs" || { bad "doc exits $RC"; tail -10 "$OUT"; }
printf '\n/// See [`does_not_exist`].\npub fn linked() {}\n' >> "$FIX/src/lib.rs"
run_phase doc
[ "$RC" -eq 1 ] && ok "a broken intra-doc link FAILS the gate" || bad "broken link passed (exit $RC)"
cp "$WORK/lib.rs.good" "$FIX/src/lib.rs"

echo "== a missing Cargo.lock fails before cargo runs =="
mv "$FIX/Cargo.lock" "$WORK/Cargo.lock.keep"
run_phase check
[ "$RC" -eq 1 ] && ok "exits 1" || bad "exits $RC, expected 1"
grep -q 'Cargo.lock is not committed' "$OUT" && ok "names the fix (commit Cargo.lock)" || bad "missing-lock message absent"
mv "$WORK/Cargo.lock.keep" "$FIX/Cargo.lock"

echo "== msrv phase refuses to run without an MSRV (no check is not a pass) =="
run_phase msrv MSRV=
[ "$RC" -eq 2 ] && ok "exits 2 (NO CHECK WAS PERFORMED)" || bad "exits $RC, expected 2"

echo "== a missing cargo is exit 2, never a pass =="
BASH_BIN="$(command -v bash)"
( cd "$FIX" && env RUST_GATE_PHASE=check PATH=/nonexistent "$BASH_BIN" --noprofile --norc -e -o pipefail "$checker" ) > "$OUT" 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok "exits 2 without cargo" || bad "exits $RC without cargo, expected 2"

# --- MUTANT: a gate whose cargo calls swallow their exit must be caught -------
echo "== mutant: 'run' that ignores the exit code =="
MUT="$WORK/mutant.sh"
perl -pe 's/^  if "\$\@"; then$/  if "\$@" || true; then/' "$checker" > "$MUT"
if grep -qF 'if "$@" || true; then' "$MUT" && bash -n "$MUT"; then
    ok "mutant parses and the mutation applied"
    printf '\n\n\nfn   ugly( ) {   }\n' >> "$FIX/src/lib.rs"
    ( cd "$FIX" && env RUST_GATE_PHASE=check CARGO_TERM_COLOR=never bash --noprofile --norc -e -o pipefail "$MUT" ) > "$OUT" 2>&1; RC=$?
    [ "$RC" -eq 0 ] && ok "mutant goes GREEN on the fmt defect — so the real gate's red above was not vacuous" \
                    || bad "mutant still failed ($RC): this suite cannot tell a gate from a no-op"
    cp "$WORK/lib.rs.good" "$FIX/src/lib.rs"
else
    bad "mutant not applied or does not parse"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
