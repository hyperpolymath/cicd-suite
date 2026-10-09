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

# --- formatting-check: a failure must NAME the file in its annotation --------
# The PR checks view shows annotations, not the log. Until this fix the gate
# printed offending paths as plain lines under an `::error::` header, so marid
# run 37448023282 annotated "Wiki content must be .md (wikis are the one .md
# home):" with no file and the path sat only in the raw log (marid#38). These
# sections plant that exact file and assert the annotation carries it.
echo "== formatting-check on the valid fixture =="
FC="$WORK/formatting.sh"; extract formatting-check > "$FC"
bash -n "$FC" || bad "extracted formatting script is not valid bash"
run_gate "$FC"
    RC=$GATE_RC; OUT="$(cat "$GATE_OUT")"
[ "$RC" -eq 0 ] && ok "exits 0 on a conformant repo" \
                || { bad "exits $RC, expected 0"; printf '%s\n' "$OUT" | sed 's/^/      /'; }
case "$OUT" in
  *"Document formatting is policy-conformant."*) ok "reaches its own success line" ;;
  *) bad "did not reach the success line" ;;
esac

# plant <path>...: create and stage files in the fixture; the gate reads
# `git ls-files`, so an unstaged file would be invisible to it.
plant() {
    local p
    for p in "$@"; do
        case "$p" in */*) [ -d "$FIX/${p%/*}" ] || mkdir -p "$FIX/${p%/*}" ;; esac
        : > "$FIX/$p"
    done
    git -C "$FIX" add -- "$@"
}
# unplant <path>...: unstage and delete what plant created.
unplant() { git -C "$FIX" rm -qrf -- "$@" >/dev/null; }

echo "== formatting-check names each failing path in its own annotation =="
plant docs/wikis/README.adoc LICENSES/MIT notes.rst
run_gate "$FC"
    RC=$GATE_RC; OUT="$(cat "$GATE_OUT")"
[ "$RC" -eq 1 ] && ok "exits 1 on three policy breaks" || bad "exits $RC, expected 1"
for want in \
    '::error file=docs/wikis/README.adoc::Wiki content must be .md (wikis are the one .md home): docs/wikis/README.adoc' \
    '::error file=LICENSES/MIT::Licence texts must be .txt: LICENSES/MIT' \
    '::error file=notes.rst::Documentation in a format the estate does not use'; do
    if printf '%s\n' "$OUT" | grep -qF -- "$want"; then
        label="${want#::error file=}"; ok "annotates ${label%%::*}"
    else
        bad "no annotation starting: $want"
    fi
done
headers="$(printf '%s\n' "$OUT" | grep -c '^::error::' || true)"
[ "$headers" -eq 1 ] && ok "the only file-less ::error:: is the summary" \
                     || bad "$headers file-less ::error:: lines, expected 1 (the summary)"
case "$OUT" in
  *"::error::Formatting gate failed: 3 file(s) break the format policy, each annotated above."*)
      ok "the summary counts the three files" ;;
  *)  bad "the summary does not count the three files" ;;
esac
unplant docs/wikis/README.adoc LICENSES/MIT notes.rst

# GitHub keeps 10 error annotations per step and silently drops the rest, so a
# gate that annotates every path loses its own summary on a big repo.
echo "== formatting-check stays within the 10-error annotation cap =="
many=()
for i in $(seq -w 1 12); do many+=("docs/wikis/page-$i.adoc"); done
plant "${many[@]}"
run_gate "$FC"
    RC=$GATE_RC; OUT="$(cat "$GATE_OUT")"
errs="$(printf '%s\n' "$OUT" | grep -c '^::error' || true)"
[ "$RC" -eq 1 ] && [ "$errs" -le 10 ] && ok "exits 1 with $errs error annotations (cap 10)" \
                                        || bad "exits $RC with $errs error annotations"
case "$OUT" in
  *"the first 9 are annotated; this step's log lists all 12."*) ok "the summary says 9 of 12 are annotated" ;;
  *) bad "the summary does not account for the paths past the cap" ;;
esac
listed=0
for p in "${many[@]}"; do printf '%s\n' "$OUT" | grep -qxF -- "$p" && listed=$((listed+1)); done
[ "$listed" -eq 12 ] && ok "the log lists all 12 paths" || bad "the log lists $listed of 12 paths"
unplant "${many[@]}"

# docs/wikis/x.rst breaks two rules (an illegal format, and non-.md wiki
# content). It is one file: one annotation, counted once, logged under both.
echo "== formatting-check counts a path two rules catch once =="
plant docs/wikis/page.rst
run_gate "$FC"
    RC=$GATE_RC; OUT="$(cat "$GATE_OUT")"
fileanns="$(printf '%s\n' "$OUT" | grep -c '^::error file=docs/wikis/page.rst::' || true)"
[ "$RC" -eq 1 ] && [ "$fileanns" -eq 1 ] && ok "exits 1 with one annotation for the doubly-failing path" \
                                          || bad "exits $RC with $fileanns annotations for docs/wikis/page.rst, expected 1"
case "$OUT" in
  *"::error::Formatting gate failed: 1 file(s) break the format policy, each annotated above."*)
      ok "the summary counts it as one file" ;;
  *)  bad "the summary does not count it as one file" ;;
esac
logged="$(printf '%s\n' "$OUT" | grep -cxF 'docs/wikis/page.rst' || true)"
[ "$logged" -eq 2 ] && ok "the log lists it under both rules" || bad "the log lists it $logged time(s), expected 2"
unplant docs/wikis/page.rst

echo "== formatting-check escapes the file= property =="
plant 'docs/wikis/a,b:c%d.adoc'
run_gate "$FC"
    OUT="$(cat "$GATE_OUT")"
want='::error file=docs/wikis/a%2Cb%3Ac%25d.adoc::Wiki content must be .md (wikis are the one .md home): docs/wikis/a,b:c%25d.adoc'
printf '%s\n' "$OUT" | grep -qxF -- "$want" && ok "file= carries %2C %3A %25; the message carries %25" \
                                             || bad "no correctly escaped annotation: $want"
unplant 'docs/wikis/a,b:c%d.adoc'

# A list longer than the pipe buffer kills `printf "$list" | head -N` with
# SIGPIPE: pipefail turns that into 141 and -e ends the step without a word.
echo "== formatting-check survives a stray .md list larger than the pipe buffer =="
strays=()
for i in $(seq -w 1 3000); do strays+=("notes/candidate-document-for-the-berrywiki-migration-$i.md"); done
plant "${strays[@]}"
run_gate "$FC"
    RC=$GATE_RC; OUT="$(cat "$GATE_OUT")"
[ "$RC" -eq 0 ] && ok "exits 0 on 3000 stray .md files" \
                || { bad "exits $RC on 3000 stray .md files, expected 0"; printf '%s\n' "$OUT" | tail -3 | sed 's/^/      /'; }
case "$OUT" in
  *"::warning::3000 .md document(s) outside wiki"*"candidates for the berrywiki migration: notes/candidate-document-for-the-berrywiki-migration-0001.md"*)
      ok "one summary warning names the count and the first paths" ;;
  *)  bad "the stray .md warning does not name the count and the first paths" ;;
esac

# --- MUTANTS: each restores one pre-fix form; the suite MUST see it ----------
echo "== mutant: reinstate printf | head on the stray list =="
FM1="$WORK/formatting-mutant-pipe.sh"
perl -pe 's/^(\s*)head -20 <<< "\$stray"$/$1printf %s\\\\n "\$stray" | head -20/' "$FC" > "$FM1"
if grep -qF 'printf %s\\n "$stray" | head -20' "$FM1" && bash -n "$FM1" 2>/dev/null; then
    ok "pipe mutant parses and the mutation applied"
    run_gate "$FM1"
        RC=$GATE_RC; OUT="$(cat "$GATE_OUT")"
    # Where SIGPIPE has its default action, printf is killed (141). Where the
    # parent ignores it, as GitHub's runner does (run 37933270247 saw rc=1),
    # printf gets EPIPE and returns 1 with "write error: Broken pipe". Either
    # way pipefail and -e end the step with no ::error::.
    if printf '%s' "$OUT" | grep -q '::error'; then
        bad "pipe mutant emitted ::error — it does not reproduce the silent kill"
    elif [ "$RC" -eq 141 ]; then
        ok "pipe mutant dies SILENTLY at 141 — the SIGPIPE kill is reproduced"
    elif [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'printf: write error: Broken pipe'; then
        ok "pipe mutant dies SILENTLY at rc=1 on EPIPE (SIGPIPE ignored here) — the kill is reproduced"
    else
        bad "pipe mutant exited $RC — the 3000-path control does not reach the pipe buffer"
        printf '%s\n' "$OUT" | tail -3 | sed 's/^/      /'
    fi
else
    bad "pipe mutant was not applied or does not parse"
fi
unplant "${strays[@]}"

echo "== mutant: reinstate the header-only ::error:: form =="
FM2="$WORK/formatting-mutant-header.sh"
perl -pe 's/^(\s*)echo "::error file=.*$/$1: # (mutant) per-path annotation removed/;
          s/^(\s*)echo "\$rule:"$/$1echo "::error::\$rule:"/' "$FC" > "$FM2"
if grep -q '(mutant) per-path annotation removed' "$FM2" && grep -qF 'echo "::error::$rule:"' "$FM2" \
   && bash -n "$FM2" 2>/dev/null; then
    ok "header mutant parses and both mutations applied"
    plant docs/wikis/README.adoc
    run_gate "$FM2"
        RC=$GATE_RC; OUT="$(cat "$GATE_OUT")"
    if [ "$RC" -eq 1 ] && ! printf '%s' "$OUT" | grep -q '::error file='; then
        ok "header mutant still fails, and names no file= — the marid#38 shape the assertions above reject"
    else
        bad "header mutant exited $RC or still emitted file= — the mutant does not reproduce the defect"
    fi
    unplant docs/wikis/README.adoc
else
    bad "header mutant was not applied or does not parse"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
