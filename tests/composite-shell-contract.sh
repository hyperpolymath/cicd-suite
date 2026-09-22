#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Composite shell contract test.
#
# GitHub runs every composite `shell: bash` step as:
#     bash --noprofile --norc -e -o pipefail {0}
#
# The `-e` is supplied by the harness, not by the script, and a script's own
# `set -uo pipefail` does NOT clear it. Any `x=$(grep ... )` is therefore a
# silent kill site whenever grep legitimately matches nothing.
#
# Two gates were dying that way on 2026-09-22 (measured on pons-asinorum):
#
#   required-files-check  a comment-only CODEOWNERS killed the step ONE LINE
#                         ABOVE the message declaring that exact file valid.
#   spdx-license-check    a repo with zero SPDX lines killed the step, making
#                         the `::warning::` branch beneath it unreachable and
#                         inverting the intent stated in its own comment.
#
# This suite reproduces the CI shell exactly, and — critically — kills a mutant.
# A gate suite that only ever goes green proves nothing.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

command -v yq >/dev/null || { echo "yq is required (Y-1: gates read YAML with yq, never grep)"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- the fixture: a repo that is VALID under every rule these gates state ----
# Solo-maintained (comment-only CODEOWNERS, explicitly valid per Rule 1) and
# carrying no SPDX headers (the case spdx-license-check exists to warn about).
FIX="$WORK/fixture"
mkdir -p "$FIX/crates"
cd "$FIX"
git init -q .
: > .editorconfig
: > .gitignore
: > .gitattributes
mkdir -p .github
cat > .github/CODEOWNERS <<'EOF'
# Solo-maintained repository.
# No path-specific owners are assigned; the sole maintainer owns everything.
EOF
cat > GOVERNANCE.adoc <<'EOF'
= Governance
This repository is maintained by a single owner.
Decisions are recorded in the issue tracker.
Changes land through pull requests.
Releases are tagged from main.
EOF
cat > ARCHITECTURE.adoc <<'EOF'
= Architecture
The implementation lives under crates/ in this repository.
Each crate is an independent unit.
Tests live beside the code they cover.
Build orchestration is a justfile.
EOF
cat > MAINTAINERS <<'EOF'
# Maintainers
hyperpolymath is the sole maintainer of this repository.
Contact goes through the issue tracker.
Security reports follow the disclosure policy.
Releases are cut by the maintainer.
Pull requests are reviewed by the maintainer before merge.
EOF
: > mise.toml
git add -A >/dev/null 2>&1
git -c user.email=t@example.invalid -c user.name=t commit -qm init >/dev/null 2>&1

# --- run a composite's script under the EXACT CI shell ----------------------
extract() { yq -r '.runs.steps[0].run' "$ROOT/actions/$1/action.yml"; }

# Runs a composite script under the exact CI shell. The result cannot come back
# through a command substitution — that would run this in a subshell and lose
# the exit code — so it lands in $GATE_OUT / $GATE_RC.
GATE_OUT="$WORK/gate.out"
run_gate() { # <script>
    ( cd "$FIX" && REPO_OWNER=hyperpolymath REPO_NAME=hyperpolymath/fixture \
        bash --noprofile --norc -e -o pipefail "$1" ) > "$GATE_OUT" 2>&1
    GATE_RC=$?
}

echo "== required-files-check on a valid solo-maintained repo =="
RF="$WORK/required-files.sh"; extract required-files-check > "$RF"
bash -n "$RF" || bad "extracted required-files script is not valid bash"
run_gate "$RF"
    RC=$GATE_RC; OUT="$(cat "$GATE_OUT")"
[ "$RC" -eq 0 ] && ok "exits 0 (was 1: -e killed it at the comment-only CODEOWNERS)" \
                || { bad "exits $RC, expected 0"; printf '%s\n' "$OUT" | sed 's/^/      /'; }
case "$OUT" in
  *"CODEOWNERS is comment-only"*) ok "prints the Rule 1 acceptance it previously died before reaching" ;;
  *) bad "never reached the Rule 1 acceptance message" ;;
esac
case "$OUT" in
  *"All required files present"*) ok "reaches its own success line" ;;
  *) bad "did not reach the success line" ;;
esac

echo "== spdx-license-check on a repo with zero SPDX headers =="
cp "$ROOT/LICENSE" "$FIX/LICENSE" 2>/dev/null || echo "MPL-2.0" > "$FIX/LICENSE"
SP="$WORK/spdx.sh"; extract spdx-license-check > "$SP"
bash -n "$SP" || bad "extracted spdx script is not valid bash"
run_gate "$SP"
    RC=$GATE_RC; OUT="$(cat "$GATE_OUT")"
[ "$RC" -eq 0 ] && ok "exits 0 (was 1: -e killed it on the zero-match git grep)" \
                || { bad "exits $RC, expected 0"; printf '%s\n' "$OUT" | sed 's/^/      /'; }
case "$OUT" in
  *"::warning::No SPDX-License-Identifier lines found"*)
      ok "the zero-SPDX warning branch is reachable at all" ;;
  *)  bad "zero-SPDX branch still unreachable — the check cannot detect what it exists for" ;;
esac

# --- MUTANT: restore the pre-fix form; the suite MUST go red ----------------
# Without this, every assertion above could be passing vacuously. Two things
# have to be true for the mutant to mean anything: it must PARSE (a mutant that
# fails `bash -n` produces a fake red), and the mutation must actually have been
# APPLIED (a no-op sed produces a fake green). Both are asserted, because both
# have already happened once while writing this file.
echo "== mutant: reinstate the unguarded count pipeline =="
MUT="$WORK/mutant.sh"
perl -pe 's/\$\(grep -cvE (.+?) \|\| true\).*$/\$(grep -vE $1 | wc -l)/' "$RF" > "$MUT"
perl -pi -e 's/^\s*set \+e\s*$/# (mutant) set +e removed\n/' "$MUT"

MUT_OK=1
grep -q 'wc -l' "$MUT"                  || { bad "mutant: count pipeline was not reinstated"; MUT_OK=0; }
grep -qE '^[[:space:]]*set \+e' "$MUT"  && { bad "mutant: set +e was not removed";           MUT_OK=0; }

if [ "$MUT_OK" -eq 1 ] && bash -n "$MUT" 2>/dev/null; then
    ok "mutant parses and both mutations applied"
    run_gate "$MUT"
    RC=$GATE_RC; OUT="$(cat "$GATE_OUT")"
    if [ "$RC" -ne 0 ]; then
        # It must die for the RIGHT reason: silently, with no ::error:: of its
        # own. A red caused by fixture drift would prove nothing about -e.
        if printf '%s' "$OUT" | grep -q '::error::'; then
            bad "mutant died with an ::error:: — that is a substance failure, not the -e kill"
        else
            ok "mutant dies SILENTLY (rc=$RC), no ::error:: — the -e kill is reproduced"
        fi
    else
        bad "mutant SURVIVED: the suite does not actually test the -e contract"
    fi
elif [ "$MUT_OK" -eq 1 ]; then
    bad "mutant does not parse — cannot prove non-vacuity"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
