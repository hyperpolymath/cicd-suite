#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Exercise language applicability under the composite action's real shell.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
out=$work/output

fail() { echo "badges-check: $1" >&2; cat "$out" >&2; exit 1; }
make_repo() {
    local repo=$1
    mkdir -p -- "$repo"
    git -C "$repo" init -q
    printf '%s\n' 'GLAMA Greenweb OpenSSF License' > "$repo/README.adoc"
    git -C "$repo" add README.adoc
}
run_check() {
    local dir=$1 script=${2:-$here/check.sh}
    if ! (cd -- "$dir" && bash --noprofile --norc -e -o pipefail "$script") > "$out" 2>&1; then
        fail 'advisory action exited unsuccessfully'
    fi
}
no_idris_advice() { ! grep -qE '^::warning::.*(Idris|RSR)' "$out"; }
has_idris_advice() {
    grep -qF "Idris source detected but 'Idris Inside' badge is missing." "$out" &&
        grep -qF 'Missing RSR-compliant badge in Idris repository.' "$out"
}

agda=$work/agda
make_repo "$agda"
mkdir "$agda/src"
printf '%s\n' 'module Witness where' > "$agda/src/Witness.agda"
git -C "$agda" add src/Witness.agda
run_check "$agda"
no_idris_advice || fail 'an Agda src/ directory was classified as Idris'
grep -qF 'accreditation standing was not assessed' "$out" || fail 'presence advice lost its assurance boundary'
echo 'ok: an Agda src/ directory is not Idris evidence'

printf '%s\n' 'module Untracked' > "$agda/Untracked.idr"
run_check "$agda"
no_idris_advice || fail 'an untracked Idris file changed language applicability'
echo 'ok: untracked files do not change language applicability'

idris=$work/idris
make_repo "$idris"
mkdir "$idris/proofs with spaces"
printf '%s\n' 'module Witness' > "$idris/proofs with spaces/Witness.idr"
git -C "$idris" add 'proofs with spaces/Witness.idr'
run_check "$idris"
has_idris_advice || fail 'a tracked nested Idris source without src/ was missed'
echo 'ok: tracked nested Idris source without src/ retains both recommendations'

package=$work/package
make_repo "$package"
printf '%s\n' 'package witness' > "$package/witness.ipkg"
git -C "$package" add witness.ipkg
run_check "$package"
has_idris_advice || fail 'a real .ipkg without src/ was missed'
rm "$package/witness.ipkg"
run_check "$package"
no_idris_advice || fail 'a deleted tracked package was treated as existing source'
echo 'ok: real package filenames are detected; deleted tracked files are excluded'

literate=$work/literate
make_repo "$literate"
printf '%s\n' '> module Witness' > "$literate/Witness.lidr"
git -C "$literate" add Witness.lidr
run_check "$literate"
has_idris_advice || fail 'tracked literate Idris source was missed'
echo 'ok: literate Idris sources retain the recommendations'

printf '%s\n' 'A project description without accreditation claims.' > "$agda/README.adoc"
run_check "$agda"
for badge in GLAMA Greenweb OpenSSF License; do
    grep -qF "::warning::Missing $badge badge in README.adoc." "$out" || fail "the $badge recommendation was suppressed"
done
no_idris_advice || fail 'missing accreditation wording changed language detection'
echo 'ok: all four existing accreditation/license recommendations remain visible'

rm "$agda/README.adoc"
run_check "$agda"
grep -qF '::warning::No README found to check badges.' "$out" || fail 'missing README was silently accepted'
echo 'ok: missing README still produces its warning'

outside=$work/outside-git
mkdir "$outside"
printf '%s\n' 'GLAMA Greenweb OpenSSF License' > "$outside/README.adoc"
run_check "$outside"
grep -qF 'Idris badge applicability NOT ASSESSED: cannot inspect tracked sources.' "$out" || fail 'a failed Git inventory was treated as no Idris sources'
echo 'ok: failed source discovery is explicitly not assessed'

# Reintroduce the original src/ shortcut in the actual implementation. The
# same Agda control must expose it; a syntax error is not a valid rejection.
mutant=$work/src-shortcut.sh
sed '/^has_idris=false$/a\if [[ -d src || -f "*.ipkg" ]]; then has_idris=true; fi' "$here/check.sh" > "$mutant"
grep -qF 'if [[ -d src || -f "*.ipkg" ]]; then has_idris=true; fi' "$mutant" || fail 'the src/ mutant was not applied'
bash -n "$mutant"
printf '%s\n' 'GLAMA Greenweb OpenSSF License' > "$agda/README.adoc"
run_check "$agda" "$mutant"
if no_idris_advice; then fail 'the Agda control accepted the original src/ detection bug'; fi
has_idris_advice || fail 'the src/ mutant failed for a different reason'
echo 'ok: the Agda control rejects the original src/ detection mutant'

echo 'badges-check controls passed'
