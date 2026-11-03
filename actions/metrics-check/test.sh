#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Log-text counts and proof status must not imply checks that never ran.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
out=$work/output
fixture=$work/fixture
mkdir "$fixture"

fail() { echo "metrics-check: $1" >&2; cat "$out" >&2; exit 1; }
run_check() {
    local path=${1:-$PATH}
    if ! (cd -- "$fixture" && PATH="$path" bash --noprofile --norc -e -o pipefail "$here/check.sh") > "$out" 2>&1; then
        fail 'advisory action exited unsuccessfully'
    fi
    if grep -qE 'Status: (NOT FULLY )?PROVEN|integer expected|integer expression expected' "$out"; then
        fail 'metrics emitted a proof verdict or an arithmetic error'
    fi
    grep -qF 'Proof status: NOT ASSESSED' "$out" || fail 'proof status lost its evidence boundary'
    grep -qF 'Log counts do not establish scan execution, freshness, or success.' "$out" || fail 'log counts were presented without their limitations'
}

run_check
for label in Pons 'Panic Attack'; do
    grep -qF "$label: NOT ASSESSED" "$out" || fail "$label missing log was not marked unassessed"
done
if grep -q 'ERROR-marker lines:' "$out"; then fail 'absent logs became zero-error counts'; fi
echo 'ok: missing logs supply no counts and no scan or proof verdict'

printf '%s\n' 'INFO: scanner startup' 'INFO: no ERROR marker on this line' > "$fixture/pons.log"
printf '%s\n' 'INFO: scanner startup' 'INFO: completed' > "$fixture/panic.log"
run_check
grep -qxF 'Pons ERROR-marker lines: 1' "$out" || fail 'Pons log text was not counted literally'
grep -qxF 'Panic Attack ERROR-marker lines: 0' "$out" || fail 'a readable zero-match log did not produce one zero count'
if grep -qx '0' "$out"; then fail 'grep no-match handling appended an extra zero'; fi
echo 'ok: existing log counts describe literal marker lines, including a valid zero'

printf '%s\n' 'ERROR one ERROR two' 'ERROR three' 'INFO only' > "$fixture/pons.log"
run_check
grep -qxF 'Pons ERROR-marker lines: 2' "$out" || fail 'the metric did not count lines rather than occurrences'
echo 'ok: repeated markers on one line are counted once'

git -C "$fixture" init -q
mkdir "$fixture/src"
printf '%s\n' 'total believe_me sorry admit' > "$fixture/src/Words.idr"
git -C "$fixture" add src/Words.idr
run_check
if grep -qE 'Escape Hatches Used:|NOT FULLY PROVEN|Status: PROVEN' "$out"; then
    fail 'source keyword matches were promoted to a proof verdict'
fi
echo 'ok: tracked proof-like words do not create a proof certification'

rm "$fixture/pons.log"
mkdir "$fixture/pons.log"
run_check
grep -qF '::warning::Pons: NOT ASSESSED (pons.log is not a readable regular file).' "$out" || fail 'a non-file log target was accepted'
if grep -qF 'Pons ERROR-marker lines:' "$out"; then fail 'an invalid log target supplied a count'; fi
echo 'ok: a non-file log target is unassessed, never a count'

rmdir "$fixture/pons.log"
printf '%s\n' 'INFO readable input' > "$fixture/pons.log"
mkdir "$work/bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 2' > "$work/bin/grep"
chmod +x "$work/bin/grep"
run_check "$work/bin:$PATH"
grep -qF '::warning::Pons: NOT ASSESSED (could not read pons.log; grep exited 2).' "$out" || fail 'a failed count operation became a number'
if grep -q 'ERROR-marker lines:' "$out"; then fail 'failed count operations supplied numbers'; fi
echo 'ok: count-tool errors remain unassessed'

echo 'metrics-check controls passed'
