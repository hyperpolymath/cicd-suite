#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Pass-on-absence controls.
#
# The defect: custom-tools-check printed "Custom tools validation
# passed" when neither pons nor panic-attack was on PATH — the normal
# case on GitHub runners — so every consumer of main-estate-audit was
# certifying scans that never ran. The audit of its sibling *-check
# composites found the same shape in contractile-validation-check
# (runner invocation commented out, unconditional "Passed") and
# proof-runner-check (only invocation commented out, unconditional
# "All detected proofs executed successfully").
#
# For each gate this suite asserts, under a PATH with no gate tools:
#   * subject present + tool absent  -> exit 2, status=not_run, and
#     NO success line anywhere in the output
#   * subject absent                 -> exit 0 only as an explicit
#     not_applicable ::notice::, never as a pass
# and with stand-in tools on PATH:
#   * tools run and exit 0           -> exit 0, and the pass line may print
#   * a tool exits non-zero          -> exit 1 (a ran-and-failed scan)
# A gate that only ever goes green proves nothing, so the stand-ins
# are what make the green assertions mean anything.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/out"

# A PATH with bash/coreutils but provably none of the gate tools.
NOBIN="$WORK/nobin"; mkdir -p "$NOBIN"
for t in bash env tr find sort cat grep cp mktemp mkdir rm; do ln -sf "$(command -v "$t")" "$NOBIN/$t"; done

run_check() { # <check.sh> <dir> <PATH> [env...]
  local script="$1" dir="$2" path="$3"; shift 3
  ( cd "$dir" && env -i PATH="$path" GITHUB_OUTPUT="$WORK/ghout" "$@" \
      bash --noprofile --norc -e -o pipefail "$script" ) > "$OUT" 2>&1
  RC=$?
  STATUS="$(sed -n 's/^status=//p' "$WORK/ghout" 2>/dev/null | tail -1)"
  cp "$WORK/ghout" "$WORK/ghout.last" 2>/dev/null || true; : > "$WORK/ghout"
}

assert_not_run() { # <label>
  [ "$RC" -eq 2 ] && ok "$1: exits 2 with tools absent" || bad "$1: exits $RC, expected 2"
  [ "$STATUS" = "not_run" ] && ok "$1: status=not_run" || bad "$1: status='$STATUS', expected not_run"
  grep -qi 'NO CHECK WAS PERFORMED' "$OUT" && ok "$1: says NO CHECK WAS PERFORMED" || bad "$1: does not say so"
  if grep -qiE 'validation passed|executed successfully|runner passed' "$OUT"; then
    bad "$1: prints a success line for a scan that never ran"
  else
    ok "$1: no success line"
  fi
}

mkstandin() { # <name> <exit-code>
  printf '#!/usr/bin/env bash\necho "stand-in %s ran ($*)"\nexit %s\n' "$1" "$2" > "$STAND/$1"
  chmod +x "$STAND/$1"
}
STAND="$WORK/stand"; mkdir -p "$STAND"

# --- custom-tools-check ------------------------------------------------------
echo "== custom-tools-check: no pons / panic-attack on PATH =="
FIX="$WORK/ct"; mkdir -p "$FIX"
run_check "$ROOT/actions/custom-tools-check/check.sh" "$FIX" "$NOBIN"
assert_not_run "custom-tools"

echo "== custom-tools-check: stand-ins run =="
mkstandin pons 0; mkstandin panic-attack 0
run_check "$ROOT/actions/custom-tools-check/check.sh" "$FIX" "$STAND:$NOBIN"
[ "$RC" -eq 0 ] && [ "$STATUS" = "passed" ] && ok "both ran clean: exits 0, status=passed" \
  || { bad "both ran clean: exits $RC status=$STATUS"; cat "$OUT"; }
grep -q 'stand-in pons ran (scan .)' "$OUT" && grep -q 'stand-in panic-attack ran (assail .)' "$OUT" \
  && ok "both tools were actually invoked" || bad "stand-ins were not both invoked"

echo "== custom-tools-check: only one tool absent is still not_run =="
rm -f "$STAND/panic-attack"
run_check "$ROOT/actions/custom-tools-check/check.sh" "$FIX" "$STAND:$NOBIN"
assert_not_run "custom-tools (panic-attack absent)"

echo "== custom-tools-check: an invalid workdir still emits not_run =="
FIX="$WORK/ct"
run_check "$ROOT/actions/custom-tools-check/check.sh" "$FIX" "$NOBIN" CUSTOM_TOOLS_WORKDIR=/nonexistent
[ "$RC" -eq 2 ] && [ "$STATUS" = "not_run" ] && ok "exits 2, status=not_run" || bad "exits $RC status=$STATUS, expected 2/not_run"

echo "== custom-tools-check: pons exit 2 (zero files analysed) is not_run, not failed =="
mkstandin pons 2; mkstandin panic-attack 0
run_check "$ROOT/actions/custom-tools-check/check.sh" "$FIX" "$STAND:$NOBIN"
[ "$RC" -eq 2 ] && [ "$STATUS" = "not_run" ] && ok "exits 2, status=not_run" || bad "exits $RC status=$STATUS, expected 2/not_run"
mkstandin pons 0

echo "== custom-tools-check: a failing tool is exit 1, not 2 and not 0 =="
mkstandin panic-attack 3
run_check "$ROOT/actions/custom-tools-check/check.sh" "$FIX" "$STAND:$NOBIN"
[ "$RC" -eq 1 ] && [ "$STATUS" = "failed" ] && ok "exits 1, status=failed" || bad "exits $RC status=$STATUS, expected 1/failed"

# --- contractile-validation-check ---------------------------------------------
# Detection half only: the verdict belongs to the DEED validator step in
# action.yml (the estate's real validator; there is no deed-lint CLI).
echo "== contractile-validation-check: declaration present is detected, not passed =="
FIX="$WORK/cv"; mkdir -p "$FIX"
printf 'contractile\n' > "$FIX/Mustfile.deed"
run_check "$ROOT/actions/contractile-validation-check/check.sh" "$FIX" "$NOBIN"
[ "$RC" -eq 0 ] && [ "$STATUS" = "detected" ] && ok "exits 0, status=detected" || { bad "exits $RC status=$STATUS, expected 0/detected"; cat "$OUT"; }
grep -q 'Passed' "$OUT" && bad "detection alone prints Passed" || ok "detection alone claims no pass"
stage="$(sed -n 's/^validate_path=//p' "$WORK/ghout.last" | tail -1)"
[ -n "$stage" ] && [ -f "$stage/Mustfile.deed" ] && [ "$(find "$stage" -type f | wc -l)" -eq 1 ] \
  && ok "only the detected declaration is staged for the validator" \
  || bad "staging wrong: '$stage' holds $(find "$stage" -type f 2>/dev/null | tr '\n' ' ')"

echo "== contractile-validation-check: Intentfile (not Intendfile) is the canonical stem =="
FIX="$WORK/cv-intent"; mkdir -p "$FIX/contractiles/intend"
printf 'contractile\n' > "$FIX/contractiles/intend/Intentfile.deed"
run_check "$ROOT/actions/contractile-validation-check/check.sh" "$FIX" "$NOBIN"
[ "$STATUS" = "detected" ] && ok "intent-only repo is detected" || { bad "intent-only repo status=$STATUS (Intendfile spelling bug?)"; cat "$OUT"; }

echo "== contractile-validation-check: the canonical .machine_readable layout is scanned =="
FIX="$WORK/cv-canonical"; mkdir -p "$FIX/.machine_readable/contractiles/intend"
printf 'contractile\n' > "$FIX/.machine_readable/contractiles/intend/Intentfile.deed"
run_check "$ROOT/actions/contractile-validation-check/check.sh" "$FIX" "$NOBIN"
[ "$STATUS" = "detected" ] && ok "canonical-layout repo is detected" || { bad "canonical-layout status=$STATUS"; cat "$OUT"; }

echo "== contractile-validation-check: staging failure is not_run, not a partial pass =="
NOCP="$WORK/nocp"; mkdir -p "$NOCP"
for t in bash env tr find sort cat grep mktemp mkdir rm; do ln -sf "$(command -v "$t")" "$NOCP/$t"; done
run_check "$ROOT/actions/contractile-validation-check/check.sh" "$WORK/cv" "$NOCP"
[ "$RC" -eq 2 ] && [ "$STATUS" = "not_run" ] && ok "no cp on PATH: exits 2, status=not_run" || { bad "exits $RC status=$STATUS, expected 2/not_run"; cat "$OUT"; }

echo "== contractile-validation-check: no declarations is not_applicable, not a pass =="
FIX="$WORK/cv-empty"; mkdir -p "$FIX"
run_check "$ROOT/actions/contractile-validation-check/check.sh" "$FIX" "$NOBIN"
[ "$RC" -eq 0 ] && [ "$STATUS" = "not_applicable" ] && ok "exits 0 as not_applicable" || bad "exits $RC status=$STATUS"
grep -q 'Passed' "$OUT" && bad "prints Passed with nothing validated" || ok "no Passed line"

echo "== contractile-validation-check: an invalid workdir still emits not_run =="
run_check "$ROOT/actions/contractile-validation-check/check.sh" "$WORK/cv-empty" "$NOBIN" CONTRACTILE_WORKDIR=/nonexistent
[ "$RC" -eq 2 ] && [ "$STATUS" = "not_run" ] && ok "exits 2, status=not_run" || bad "exits $RC status=$STATUS, expected 2/not_run"

# --- proof-runner-check ---------------------------------------------------------
echo "== proof-runner-check: .ipkg present, idris2 absent =="
FIX="$WORK/pr"; mkdir -p "$FIX"
printf 'package fixture\n' > "$FIX/abi.ipkg"
run_check "$ROOT/actions/proof-runner-check/check.sh" "$FIX" "$NOBIN"
assert_not_run "proof-runner"

echo "== proof-runner-check: no proof project is not_applicable, not 'executed' =="
FIX="$WORK/pr-empty"; mkdir -p "$FIX"
run_check "$ROOT/actions/proof-runner-check/check.sh" "$FIX" "$NOBIN"
[ "$RC" -eq 0 ] && [ "$STATUS" = "not_applicable" ] && ok "exits 0 as not_applicable" || bad "exits $RC status=$STATUS"
grep -qi 'executed successfully' "$OUT" && bad "claims proofs executed with none present" || ok "no execution claim"

echo "== proof-runner-check: idris2 stand-in runs =="
mkstandin idris2 0
FIX="$WORK/pr"; run_check "$ROOT/actions/proof-runner-check/check.sh" "$FIX" "$STAND:$NOBIN"
[ "$RC" -eq 0 ] && [ "$STATUS" = "passed" ] && ok "exits 0, status=passed" || { bad "exits $RC status=$STATUS"; cat "$OUT"; }

echo "== proof-runner-check: a failing idris2 is exit 1 =="
mkstandin idris2 5
run_check "$ROOT/actions/proof-runner-check/check.sh" "$WORK/pr" "$STAND:$NOBIN"
[ "$RC" -eq 1 ] && [ "$STATUS" = "failed" ] && ok "exits 1, status=failed" || bad "exits $RC status=$STATUS, expected 1/failed"

echo "== proof-runner-check: a Lean project in a subdirectory is found and built there =="
printf '#!/usr/bin/env bash\necho "stand-in lake ran in $PWD"\nexit 0\n' > "$STAND/lake"; chmod +x "$STAND/lake"
FIX="$WORK/pr-lean"; mkdir -p "$FIX/proofs/sub"
printf 'name = "sub"\n' > "$FIX/proofs/sub/lakefile.toml"
run_check "$ROOT/actions/proof-runner-check/check.sh" "$FIX" "$STAND:$NOBIN"
[ "$RC" -eq 0 ] && [ "$STATUS" = "passed" ] && ok "subdir lakefile: exits 0, status=passed" || { bad "exits $RC status=$STATUS"; cat "$OUT"; }
grep -q "stand-in lake ran in $FIX/proofs/sub" "$OUT" && ok "lake build ran in the project directory" || { bad "lake did not run in the project directory"; cat "$OUT"; }

echo "== proof-runner-check: lakefiles under .lake (dependencies) are not projects =="
FIX="$WORK/pr-lake-dep"; mkdir -p "$FIX/.lake/packages/dep"
printf 'name = "root"\n' > "$FIX/lakefile.toml"
printf 'name = "dep"\n' > "$FIX/.lake/packages/dep/lakefile.toml"
run_check "$ROOT/actions/proof-runner-check/check.sh" "$FIX" "$STAND:$NOBIN"
[ "$RC" -eq 0 ] && [ "$STATUS" = "passed" ] && ok "exits 0, status=passed" || { bad "exits $RC status=$STATUS"; cat "$OUT"; }
[ "$(grep -c 'stand-in lake ran' "$OUT")" -eq 1 ] && ok "lake ran once (root only, .lake pruned)" || { bad "lake ran $(grep -c 'stand-in lake ran' "$OUT") times, expected 1"; cat "$OUT"; }

echo "== proof-runner-check: incomplete discovery is not_run, never a quiet pass =="
FIX="$WORK/pr-locked"; mkdir -p "$FIX/locked"
printf 'package hidden\n' > "$FIX/locked/abi.ipkg"
chmod 000 "$FIX/locked"
if [ "$(id -u)" -ne 0 ]; then
  run_check "$ROOT/actions/proof-runner-check/check.sh" "$FIX" "$STAND:$NOBIN"
  [ "$RC" -eq 2 ] && [ "$STATUS" = "not_run" ] && ok "unreadable tree: exits 2, status=not_run" || { bad "unreadable tree exits $RC status=$STATUS"; cat "$OUT"; }
else
  ok "unreadable-tree control skipped (running as root: permissions do not bite)"
fi
chmod 755 "$FIX/locked"

# --- the fixed gates must not be back in the estate audit -----------------------
# main-estate-audit installs none of these tools; a step there would be
# red estate-wide (exit 2) or, before this fix, green for nothing.
echo "== main-estate-audit does not run the tool-dependent gates it cannot feed =="
for a in custom-tools-check contractile-validation-check proof-runner-check; do
  if grep -q "actions/$a@" "$ROOT/.github/workflows/main-estate-audit.yml"; then
    bad "main-estate-audit still runs $a without installing its tool"
  else
    ok "main-estate-audit does not run $a"
  fi
done

echo
echo "pass-on-absence: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
