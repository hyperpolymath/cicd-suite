#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Conformance test for proven/registry/sq-map.tsv, the one map between Hypatia
# A5 rule ids and squabbler rule ids. The squabbler and Hypatia can both run it.
#
#   SQUABBLER_RULES=<first-line-rules.tsv>   also check the map against the table
#   HYPATIA_PRAXIS=<hypatia_rules_praxis.deed> also check the praxis column
#
# The kernel-reason rows are checked against src/Proven/Lock/Judge.idr when it
# exists. A cross-check whose input is named but missing is NOT RUN (exit 2),
# never a silent pass. Exit: 0 conforms, 1 a rule is broken, 2 not run.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
map=${SQ_MAP:-$root/proven/registry/sq-map.tsv}
[[ -f $map ]] || { echo "registry-sq-map: $map missing; NOT RUN" >&2; exit 2; }

fail=0
bad() { echo "FAIL $*"; fail=1; }

[[ $(head -n 1 "$map") == $'a5_id\tsq_id\tstatus\tpraxis\tnote' ]] || bad "header is not a5_id sq_id status praxis note"
rows=$(tail -n +2 "$map")
[[ -n $rows ]] || { echo "registry-sq-map: no rows; no assurance" >&2; exit 2; }

# Shape and per-row rules.
while IFS= read -r line; do
  bad "$line"
done < <(awk -F'\t' '
  NF != 5 { print "row " NR+1 ": " NF " fields, want 5"; next }
  $1 != "-" && $1 !~ /^hypatia\/[a-z0-9_]+\/[A-Za-z0-9_]+$/ { print "row " NR+1 ": a5_id " $1 " is not hypatia/<module>/<name>" }
  $2 != "hypatia-only" && !($2 == "unassigned" && $3 == "kernel-reason") && $2 !~ /^SQ-[A-Z]+-[0-9][0-9]$/ { print "row " NR+1 ": sq_id " $2 " is not SQ-<FAMILY>-NN or hypatia-only" }
  $1 != "-" && $3 == "mapped" && $2 == "hypatia-only" { print "row " NR+1 ": mapped row has no SQ id" }
  $1 != "-" && $3 == "hypatia-only" && $2 != "hypatia-only" { print "row " NR+1 ": hypatia-only row names " $2 }
  $1 != "-" && $3 != "mapped" && $3 != "hypatia-only" { print "row " NR+1 ": an A5 row must be mapped or hypatia-only, not " $3 }
  $1 != "-" && $4 != "present" && $4 != "absent" { print "row " NR+1 ": praxis must be present or absent" }
  $1 == "-" && $3 != "squabbler-only" && $3 != "kernel-reason" { print "row " NR+1 ": a row without an A5 id must be squabbler-only or kernel-reason" }
  $1 == "-" && $4 != "-" { print "row " NR+1 ": praxis must be - when there is no A5 id" }
  $3 == "kernel-reason" && $5 !~ /^[A-Z][A-Za-z]+$/ { print "row " NR+1 ": kernel-reason note must be the reason name" }
' <<<"$rows")

# Every A5 id appears exactly once.
dups=$(awk -F'\t' '$1 != "-" {print $1}' <<<"$rows" | sort | uniq -d)
[[ -z $dups ]] || bad "A5 ids appear more than once: $(tr '\n' ' ' <<<"$dups")"

# An SQ id is either mapped somewhere or listed squabbler-only, not both.
both=$(comm -12 <(awk -F'\t' '$3=="squabbler-only"{print $2}' <<<"$rows" | sort -u) \
                <(awk -F'\t' '$3=="mapped"{print $2}' <<<"$rows" | sort -u))
[[ -z $both ]] || bad "SQ ids both mapped and squabbler-only: $(tr '\n' ' ' <<<"$both")"

if [[ -n ${SQUABBLER_RULES:-} ]]; then
  [[ -f $SQUABBLER_RULES ]] || { echo "SQUABBLER_RULES=$SQUABBLER_RULES missing; NOT RUN" >&2; exit 2; }
  table=$(awk -F'\t' '$1 ~ /^SQ-[A-Z]+-[0-9][0-9]$/ {print $1}' "$SQUABBLER_RULES" | sort -u)
  [[ -n $table ]] || { echo "no SQ ids read from $SQUABBLER_RULES; NOT RUN" >&2; exit 2; }
  named=$(awk -F'\t' '$2 ~ /^SQ-/ {print $2}' <<<"$rows" | sort -u)
  missing=$(comm -23 <(echo "$table") <(echo "$named"))
  unknown=$(comm -13 <(echo "$table") <(echo "$named"))
  [[ -z $missing ]] || bad "SQ ids in the table but not in the map: $(tr '\n' ' ' <<<"$missing")"
  [[ -z $unknown ]] || bad "SQ ids in the map but not in the table: $(tr '\n' ' ' <<<"$unknown")"
  echo "checked against $(wc -l <<<"$table") squabbler rules"
fi

if [[ -n ${HYPATIA_PRAXIS:-} ]]; then
  [[ -f $HYPATIA_PRAXIS ]] || { echo "HYPATIA_PRAXIS=$HYPATIA_PRAXIS missing; NOT RUN" >&2; exit 2; }
  registry=$(grep -oE 'hypatia/[a-z0-9_]+/[A-Za-z0-9_]+' "$HYPATIA_PRAXIS" | sort -u)
  [[ -n $registry ]] || { echo "no A5 ids read from $HYPATIA_PRAXIS; NOT RUN" >&2; exit 2; }
  while IFS=$'\t' read -r a5 _ _ praxis _; do
    [[ $a5 == - ]] && continue
    if grep -qxF -- "$a5" <<<"$registry"; then actual=present; else actual=absent; fi
    [[ $actual == "$praxis" ]] || bad "$a5: praxis column says $praxis, registry says $actual"
  done <<<"$rows"
  echo "checked against $(wc -l <<<"$registry") praxis ids"
fi

judge=$root/src/Proven/Lock/Judge.idr
if [[ -f $judge ]]; then
  emitted=$(grep -oE '^fields \([A-Za-z]+[^=]*= \("[A-Za-z]+"' "$judge" | grep -oE '"[A-Za-z]+"$' | tr -d '"' | sort -u)
  [[ -n $emitted ]] || { echo "no reason names read from $judge; NOT RUN" >&2; exit 2; }
  listed=$(awk -F'\t' '$3=="kernel-reason"{print $5}' <<<"$rows" | sort -u)
  [[ $emitted == "$listed" ]] || bad "kernel-reason rows differ from the reasons the kernel emits: $(diff <(echo "$emitted") <(echo "$listed") | tr '\n' ' ')"
fi

unassigned=$(awk -F'\t' '$2=="unassigned"{print $5}' <<<"$rows" | tr '\n' ' ')
[[ -z $unassigned ]] || echo "WARN kernel reasons with no agreed SQ rule: $unassigned"
[[ $fail == 0 ]] && echo "registry-sq-map: $(wc -l <<<"$rows") rows conform"
exit "$fail"
