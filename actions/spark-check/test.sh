#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# test.sh — the SPARK gate must fail for each thing it claims to check, under
# the exact composite shell. GNATprove is replaced by a stand-in on PATH that
# honours the one contract the gate relies on: non-zero exit (and a
# `medium:` message) when a source under the project contains the planted
# failing marker or a `--  UNPROVED` line; zero otherwise. A yes-only
# stand-in must make the gate refuse (exit 2). The real prover is exercised
# by the planted controls in check.sh on every live run.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="$here/check.sh"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/out"
FIX="$WORK/fixture"

fresh_fixture() {
    rm -rf "$FIX"; mkdir -p "$FIX/spark/src"
    git -C "$FIX" init -q
    git -C "$FIX" config user.email t@example.invalid
    git -C "$FIX" config user.name t
    printf 'project Gate is\n   for Source_Dirs use ("src");\n   for Object_Dir use "obj";\nend Gate;\n' > "$FIX/spark/gate.gpr"
    cat > "$FIX/spark/src/gate.ads" <<'ADA'
--  A tiny SPARK unit.
package Gate with SPARK_Mode => On is
   function Id (X : Integer) return Integer with Post => Id'Result = X;
end Gate;
ADA
    printf 'package body Gate with SPARK_Mode => On is\n   function Id (X : Integer) return Integer is (X);\nend Gate;\n' > "$FIX/spark/src/gate.adb"
    git -C "$FIX" add -A && git -C "$FIX" commit -qm fixture
}
commit() { git -C "$FIX" add -A && git -C "$FIX" commit -qm change >/dev/null; }
run_phase() { # <phase> [env...]
    ( cd "$FIX" && env SPARK_GATE_PHASE="$1" "${@:2}" bash --noprofile --norc -e -o pipefail "$checker" ) > "$OUT" 2>&1
    RC=$?
}

STAND_IN="$WORK/bin"; mkdir -p "$STAND_IN"
write_oracle() {
cat > "$STAND_IN/gnatprove" <<'SH'
#!/usr/bin/env bash
# stand-in gnatprove: -P <gpr>; sources under <gpr dir>/src; marker → unproved
gpr=""
for a in "$@"; do case "$a" in *.gpr) gpr="$a" ;; esac; done
[ -n "$gpr" ] || { echo "stand-in: no project" >&2; exit 2; }
d="$(dirname "$gpr")"
mkdir -p "$d/obj/gnatprove"
if grep -rqE 'Planted_Must_Fail|--  UNPROVED' "$d/src" 2>/dev/null; then
  f="$(grep -rlE 'Planted_Must_Fail|--  UNPROVED' "$d/src" | head -n 1)"
  echo "$f:2:4: medium: postcondition might fail"
  printf 'Summary of SPARK analysis\n Total: 1 unproved\n' > "$d/obj/gnatprove/gnatprove.out"
  exit 1
fi
printf 'Summary of SPARK analysis\n Total: all proved\n' > "$d/obj/gnatprove/gnatprove.out"
echo "stand-in: all checks proved"
exit 0
SH
chmod +x "$STAND_IN/gnatprove"
}
write_oracle

echo "== detect on a one-project SPARK tree =="
fresh_fixture
run_phase detect
[ "$RC" -eq 0 ] && ok "detect exits 0" || { bad "detect exits $RC"; cat "$OUT"; }
grep -qx 'spark_units=2' "$OUT" && ok "counts both SPARK_Mode-On units" || bad "unit count wrong: $(cat "$OUT")"
grep -qx 'project=spark/gate.gpr' "$OUT" && ok "picks the single .gpr" || bad "project not picked"

echo "== detect refuses to guess between two projects =="
cp "$FIX/spark/gate.gpr" "$FIX/spark/other.gpr"; commit
run_phase detect
[ "$RC" -eq 1 ] && ok "exits 1 with two .gpr and no input" || bad "exits $RC, expected 1"
grep -q 'will not guess' "$OUT" && ok "says it will not guess" || bad "no explanation"
run_phase detect GPR=spark/gate.gpr
[ "$RC" -eq 0 ] && ok "an explicit gpr input resolves it" || bad "gpr input not honoured (exit $RC)"
git -C "$FIX" rm -q spark/other.gpr; commit

echo "== a commented-out SPARK_Mode is not a unit =="
printf -- '--  with SPARK_Mode => On\npackage Dormant is\nend Dormant;\n' > "$FIX/spark/src/dormant.ads"; commit
run_phase detect
grep -qx 'spark_units=2' "$OUT" && ok "comment-only SPARK_Mode is ignored" || bad "comment counted as a unit"

echo "== prove with a stand-in oracle that can say no =="
run_phase prove PATH="$STAND_IN:$PATH"
[ "$RC" -eq 0 ] && ok "prove exits 0 when all checks prove" || { bad "prove exits $RC"; cat "$OUT"; }
grep -q 'false postcondition refused' "$OUT" && ok "failing control exercised" || bad "failing control not run"
grep -q 'true postcondition proved' "$OUT" && ok "passing control exercised" || bad "passing control not run"
grep -q 'GNATprove summary' "$OUT" && ok "the summary is printed" || bad "summary not printed"
printf -- '--  UNPROVED\n' >> "$FIX/spark/src/gate.adb"; commit
run_phase prove PATH="$STAND_IN:$PATH"
[ "$RC" -eq 1 ] && ok "an unproved check fails the gate" || bad "unproved exits $RC, expected 1"
grep -q 'medium: postcondition might fail' "$OUT" && ok "the unproved message is in the log" || bad "message missing"
grep -q '::error file=spark/gate.gpr::spark-check\[prove\]' "$OUT" && ok "the project is annotated" || bad "project not annotated"
git -C "$FIX" checkout -q HEAD~1 -- spark/src/gate.adb; commit

echo "== prove: zero exit but an unproved message is still not a pass =="
cat > "$STAND_IN/gnatprove" <<'SH'
#!/usr/bin/env bash
echo "src/gate.adb:2:4: medium: postcondition might fail"; exit 0
SH
run_phase prove PATH="$STAND_IN:$PATH"
[ "$RC" -ne 0 ] && ok "not a pass (exit $RC)" || bad "zero exit with 'medium:' passed"

echo "== prove: an oracle that can only say yes makes the verdict VOID =="
printf '#!/usr/bin/env bash\necho yes; exit 0\n' > "$STAND_IN/gnatprove"
run_phase prove PATH="$STAND_IN:$PATH"
[ "$RC" -eq 2 ] && ok "exits 2 (NO PROOF WAS PERFORMED)" || bad "exits $RC, expected 2"
grep -q 'cannot fail' "$OUT" && ok "says the prover cannot fail" || bad "no explanation"

echo "== prove without gnatprove is exit 2 =="
rm -f "$STAND_IN/gnatprove"
NOBIN="$WORK/nobin"; mkdir -p "$NOBIN"
for t in git grep sed awk tr dirname basename head wc find sort cat mktemp env tee; do ln -sf "$(command -v "$t")" "$NOBIN/$t"; done
BASH_BIN="$(command -v bash)"
( cd "$FIX" && env SPARK_GATE_PHASE=prove PATH="$NOBIN" "$BASH_BIN" --noprofile --norc -e -o pipefail "$checker" ) > "$OUT" 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok "exits 2 without the tool" || bad "exits $RC without the tool, expected 2 ($(tail -1 "$OUT"))"
write_oracle

echo "== prove on a tree with no SPARK units is exit 2, not green =="
git -C "$FIX" rm -q spark/src/gate.ads spark/src/gate.adb; commit
run_phase prove PATH="$STAND_IN:$PATH"
[ "$RC" -eq 2 ] && ok "exits 2 with nothing to prove" || bad "exits $RC, expected 2"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
