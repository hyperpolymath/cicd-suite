#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# contractile-validation-check — detection half of the gate.
#
# Same pass-on-absence defect as the old custom-tools-check: the inline
# version echoed "Invoking $runner runner..." in front of a commented-out
# command and printed "Contractile Validation Passed." unconditionally.
# Its first fix then required a `deed-lint` executable — a name taken
# from that same commented-out `# e.g.` placeholder. No such CLI exists
# (Codex review, PR #58); the estate's real DEED validator is
# hyperpolymath/deed-ecosystem/validate-action, the action
# manifest-check already pins. So this script does only the honest
# local half — find the declarations — and action.yml runs that
# validator when, and only when, declarations are present.
#
# Outputs (to $GITHUB_OUTPUT):
#   has_declarations  true | false
#   status            not_applicable (none found) | detected (found;
#                     validation is the validator step's verdict, and
#                     action.yml only prints "passed" after it runs)
# Exit 2 if the scan root cannot be entered: NO CHECK WAS PERFORMED
# (status=not_run). Never a pass from this script.
#
# Declarations are <Verb>file.deed (standards #837: a2ml is retired and
# is not read here), at the root or under contractiles/<verb>/. Note
# the irregular stem: the canonical name is Intentfile, not Intendfile
# (hyperpolymath/contractiles), so stems are mapped explicitly rather
# than derived by capitalisation.

set -uo pipefail

emit_status() {
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "status=$1" >> "$GITHUB_OUTPUT"
  echo "contractile-validation-check status=$1"
}

dir="${CONTRACTILE_WORKDIR:-.}"
cd "$dir" || { emit_status not_run; echo "::error::contractile-validation-check: cannot enter $dir — NO CHECK WAS PERFORMED (status=not_run)." >&2; exit 2; }

declare -A stems=( [must]=Mustfile [trust]=Trustfile [adjust]=Adjustfile
                   [dust]=Dustfile [bust]=Bustfile [intend]=Intentfile )

# Search roots: the repository root, contractiles/<verb>/, and the
# estate's canonical serialization layout
# .machine_readable/contractiles/ (with or without a <verb>/ level) —
# hyperpolymath/contractiles documents that hierarchy as canonical, and
# missing it reported such a repository not_applicable without ever
# invoking the validator.
declare -a decls=()
for runner in must trust adjust dust bust intend; do
  for f in "${stems[$runner]}.deed" \
           "contractiles/$runner/${stems[$runner]}.deed" \
           ".machine_readable/contractiles/${stems[$runner]}.deed" \
           ".machine_readable/contractiles/$runner/${stems[$runner]}.deed"; do
    [ -f "$f" ] && decls+=("$f")
  done
done

# The k9 self-validating folder is presence-only evidence: report it,
# never count it as validation.
if [ -d ".machine_readable/k9" ] || [ -d "contractiles/k9" ]; then
  echo "::notice::contractile-validation-check: self-validating k9 folder present (presence noted; its contents are not validated by this gate)."
fi

if [ "${#decls[@]}" -eq 0 ]; then
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "has_declarations=false" >> "$GITHUB_OUTPUT"
  emit_status not_applicable
  echo "::notice::contractile-validation-check: no contractile declarations (<Verb>file.deed) found — not applicable, nothing was validated."
  exit 0
fi

# Stage ONLY the detected declarations for the validator. Handing it
# the scan root would validate every unrelated .deed — and legacy
# .a2ml, which this gate says is retired — below it, so an unrelated
# broken manifest could fail an otherwise valid contractile gate.
#
# Fail closed, portably: no `cp --parents` (GNU-only; BSD cp on macOS
# runners rejects it), and every step is checked — a partial stage
# that still advertised has_declarations=true would let the validator
# succeed over some or none of the declarations and the verdict would
# report passed. has_declarations is therefore written only AFTER the
# stage is complete.
stage="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/contractile-validation-XXXXXXXX")" || {
  emit_status not_run
  echo "::error::contractile-validation-check: cannot create the staging directory — NO CHECK WAS PERFORMED (status=not_run)." >&2
  exit 2
}
for f in "${decls[@]}"; do
  dest="$stage/$f"
  if ! mkdir -p "${dest%/*}" || ! cp "$f" "$dest"; then
    emit_status not_run
    echo "::error::contractile-validation-check: cannot stage $f — NO CHECK WAS PERFORMED (status=not_run)." >&2
    exit 2
  fi
done
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "validate_path=$stage" >> "$GITHUB_OUTPUT"
  echo "has_declarations=true" >> "$GITHUB_OUTPUT"
fi

emit_status detected
echo "contractile-validation-check: ${#decls[@]} declaration(s) found: ${decls[*]} — staged at $stage; the DEED validator step decides the verdict."
