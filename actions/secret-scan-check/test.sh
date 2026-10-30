#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Empirical controls; set GITLEAKS_BIN to run these with the real pinned binary.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [[ -z ${GITLEAKS_BIN:-} ]]; then
    cat >"$tmp/gitleaks" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ ${FAKE_ERROR:-0} != 1 ]] || exit 3
[[ $1 != version ]] || { echo fixture; exit 0; }
[[ ${FAKE_IGNORE:-0} != 1 ]] || { cat >/dev/null; exit 0; }
case $1 in
 stdin) content=$(cat) ;;
 dir) content=$(find . -type f -not -path './.git/*' -not -name '.gitleaks*' -exec cat {} +) ;;
 git) shift; shift; [[ $1 == --log-opts ]]; content=$(git log --format= -p "$2") ;;
 *) exit 3 ;;
esac
if grep -q 'ghp_' <<<"$content"; then exit 10; fi
MOCK
    chmod +x "$tmp/gitleaks"
    export GITLEAKS_BIN="$tmp/gitleaks"
    echo 'Using stand-in scanner: shell/control-flow evidence only.'
else
    export GITLEAKS_BIN
    echo 'Using real scanner: detection and control-flow evidence.'
fi
export ESTATE_BASELINE="$root/config/gitleaks/estate-baseline.toml" SCAN_TIMEOUT_SECONDS=15
fixture() {
    mkdir "$tmp/$1"
    git -C "$tmp/$1" init -q
    git -C "$tmp/$1" config user.name control
    git -C "$tmp/$1" config user.email control@example.invalid
    echo clean >"$tmp/$1/readme.txt"
    git -C "$tmp/$1" add .
    git -C "$tmp/$1" commit -qm clean
    export SUBJECT="$tmp/$1" BASE_SHA
    BASE_SHA=$(git -C "$SUBJECT" rev-parse HEAD)
}
commit() { git -C "$SUBJECT" add .; git -C "$SUBJECT" commit -qm control; }
expect() {
    local expected=$1 label=$2 rc=0
    HEAD_SHA=$(git -C "$SUBJECT" rev-parse HEAD) bash "$root/actions/secret-scan-check/check.sh" >"$tmp/output" 2>&1 || rc=$?
    if [[ $rc != "$expected" ]]; then cat "$tmp/output"; echo "FAIL $label: wanted $expected got $rc"; exit 1; fi
    echo "ok: $label"
}
fixture clean
SCAN_MODE=full expect 0 'clean full history and tree'
SCAN_MODE=pr-range expect 0 'empty introduced range still scans the tree'
# Build three PR commits. Final tree and BASE..HEAD file diff are clean.
printf '%s_%s\n' ghp Q7mN2aR9vB4cD6eF8gH1jK3pL5sT0uV2wX4z >"$SUBJECT/key.txt"
commit
rm "$SUBJECT/key.txt"
commit
SCAN_MODE=pr-range expect 1 'intermediate committed-then-deleted credential'
SCAN_MODE=full expect 1 'deleted credential remains in full history'
fixture documentation
printf '%s_%s\n' ghp Q7mN2aR9vB4cD6eF8gH1jK3pL5sT0uV2wX4z >"$SUBJECT/guide.adoc"
commit
SCAN_MODE=pr-range expect 1 'AsciiDoc credential detected without a mirror pass'
fixture untracked
printf '%s_%s\n' ghp Q7mN2aR9vB4cD6eF8gH1jK3pL5sT0uV2wX4z >"$SUBJECT/untracked.txt"
SCAN_MODE=pr-range expect 1 'untracked tree credential'
fixture wrongbase
BASE_SHA=0000000000000000000000000000000000000000 SCAN_MODE=pr-range expect 2 'missing base refuses a verdict'
echo mismatch >"$SUBJECT/.gitleaks-estate.toml"
SCAN_MODE=full expect 2 'conflicting baseline refuses a verdict'
rm "$SUBJECT/.gitleaks-estate.toml"
# A genuinely shallow local clone must not become a one-commit full audit.
git clone -q --depth 1 "file://$SUBJECT" "$tmp/shallow"
SUBJECT="$tmp/shallow" SCAN_MODE=full expect 2 'shallow history refuses a verdict'
if [[ $GITLEAKS_BIN == "$tmp/gitleaks" ]]; then
    FAKE_ERROR=1 SCAN_MODE=full expect 2 'scanner infrastructure error is not a pass'
    FAKE_IGNORE=1 SCAN_MODE=full expect 2 'vacuous scanner mutant killed by live control'
fi
