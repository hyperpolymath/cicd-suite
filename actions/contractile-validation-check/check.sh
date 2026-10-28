#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# contractile-validation-check — contractile declarations vs their runner.
#
# Same pass-on-absence defect as the old custom-tools-check: the inline
# version echoed "Invoking $runner runner..." in front of a commented-out
# command and printed "Contractile Validation Passed." unconditionally.
#
# Contract:
#   0  no contractile declarations in the tree (not applicable, said so
#      with ::notice:: — never "Passed"), OR deed-lint was on PATH, ran
#      on every declaration, and exited 0 for each
#   1  deed-lint ran and rejected a declaration
#   2  declarations are present but deed-lint is not on PATH —
#      NO CHECK WAS PERFORMED (status=not_run). Never a pass.
#
# Declarations are <Verb>file.deed (standards #837: a2ml is retired and
# is not read here), at the root or under contractiles/<verb>/.

set -uo pipefail

dir="${CONTRACTILE_WORKDIR:-.}"
cd "$dir" || { echo "::error::contractile-validation-check: cannot enter $dir — NO CHECK WAS PERFORMED." >&2; exit 2; }

emit_status() {
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "status=$1" >> "$GITHUB_OUTPUT"
  echo "contractile-validation-check status=$1"
}

declare -a decls=() verbs=()
for runner in must trust adjust dust bust intend; do
  stem="$(tr '[:lower:]' '[:upper:]' <<< "${runner:0:1}")${runner:1}file"
  for f in "$stem.deed" "contractiles/$runner/$stem.deed"; do
    [ -f "$f" ] && { decls+=("$f"); verbs+=("$runner"); }
  done
done

# The k9 self-validating folder is presence-only evidence: report it,
# never count it as validation.
if [ -d ".machine_readable/k9" ] || [ -d "contractiles/k9" ]; then
  echo "::notice::contractile-validation-check: self-validating k9 folder present (presence noted; its contents are not validated by this gate)."
fi

if [ "${#decls[@]}" -eq 0 ]; then
  emit_status not_applicable
  echo "::notice::contractile-validation-check: no contractile declarations (<Verb>file.deed) found — not applicable, nothing was validated."
  exit 0
fi

if ! command -v deed-lint >/dev/null 2>&1; then
  emit_status not_run
  echo "::error::contractile-validation-check: ${#decls[@]} contractile declaration(s) present (${decls[*]}) but 'deed-lint' is not on PATH — NO CHECK WAS PERFORMED (status=not_run). Install deed-lint before this step, or do not call this gate." >&2
  exit 2
fi

fail=0
for i in "${!decls[@]}"; do
  echo "Running: deed-lint ${decls[$i]} --runner=${verbs[$i]}"
  deed-lint "${decls[$i]}" --runner="${verbs[$i]}" \
    || { rc=$?; echo "::error::contractile-validation-check: deed-lint exited $rc on ${decls[$i]}."; fail=1; }
done

if [ "$fail" -eq 1 ]; then
  emit_status failed
  exit 1
fi

emit_status passed
echo "Contractile validation passed (deed-lint ran on ${#decls[@]} declaration(s) and exited 0 for each)."
