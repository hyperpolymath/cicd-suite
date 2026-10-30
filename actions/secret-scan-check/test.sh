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
if [[ ${REQUIRE_TRUSTED_CONFIG:-0} == 1 ]]; then
    [[ -f .gitleaks.toml && -f policy.toml ]] || exit 3
    ! grep -q 'paths =' .gitleaks.toml policy.toml || exit 3
fi
case $1 in
 stdin) content=$(cat) ;;
 dir) content=$(find "$2" -type f -not -path '*/.git/*' -not -name '.gitleaks*' -exec cat {} +) ;;
 git) source=$2; shift; shift; [[ $1 == --log-opts ]]; content=$(git -C "$source" log --format= -p "$2") ;;
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
export ESTATE_BASELINE="$root/config/gitleaks/estate-baseline.toml" SCAN_TIMEOUT_SECONDS=15 GITHUB_EVENT_NAME=push
fixture() {
    local name=$1
    mkdir "$tmp/$name"
    git -C "$tmp/$name" init -q
    git -C "$tmp/$name" config user.name control
    git -C "$tmp/$name" config user.email control@example.invalid
    echo clean >"$tmp/$name/readme.txt"
    git -C "$tmp/$name" add .
    git -C "$tmp/$name" commit -qm clean
    export SUBJECT="$tmp/$name" BASE_SHA
    BASE_SHA=$(git -C "$SUBJECT" rev-parse HEAD)
}
commit() { git -C "$SUBJECT" add .; git -C "$SUBJECT" commit -qm control; }
expect() {
    local expected=$1 label=$2 rc=0
    HEAD_SHA=$(git -C "$SUBJECT" rev-parse HEAD) PR_HEAD=$(git -C "$SUBJECT" rev-parse HEAD) \
        PR_BASE=${PR_BASE:-$BASE_SHA} bash "$root/actions/secret-scan-check/check.sh" >"$tmp/output" 2>&1 || rc=$?
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
fixture prconfig
cat >"$SUBJECT/.gitleaks.toml" <<'CONFIG'
[extend]
path = "policy.toml"
CONFIG
printf '[extend]\nuseDefault = true\n' >"$SUBJECT/policy.toml"
echo '# trusted ignore' >"$SUBJECT/.gitleaksignore"
commit
BASE_SHA=$(git -C "$SUBJECT" rev-parse HEAD)
printf '%s_%s\n' ghp Q7mN2aR9vB4cD6eF8gH1jK3pL5sT0uV2wX4z >"$SUBJECT/key.txt"
cat >>"$SUBJECT/.gitleaks.toml" <<'CONFIG'
[allowlist]
paths = ['''.*''']
CONFIG
commit
cat >>"$SUBJECT/policy.toml" <<'CONFIG'
[allowlist]
paths = ['''.*''']
CONFIG
commit
GITHUB_EVENT_NAME=pull_request REQUIRE_TRUSTED_CONFIG=1 SCAN_MODE=full expect 1 'PR full scan uses base config and extension'
GITHUB_EVENT_NAME=pull_request REQUIRE_TRUSTED_CONFIG=1 SCAN_MODE=pr-range expect 1 'PR range scan uses base config and extension'
echo 'untrusted suppression' >>"$SUBJECT/.gitleaksignore"
GITHUB_EVENT_NAME=pull_request SCAN_MODE=full expect 2 'changed PR ignore file refused'
rm "$SUBJECT/.gitleaksignore"
GITHUB_EVENT_NAME=pull_request SCAN_MODE=full expect 2 'deleted PR ignore file refused'
fixture prignore
echo 'untrusted suppression' >"$SUBJECT/.gitleaksignore"
GITHUB_EVENT_NAME=pull_request SCAN_MODE=full expect 2 'new PR ignore file refused'
fixture prescape
printf '[extend]\npath = "policy.toml"\n' >"$SUBJECT/.gitleaks.toml"
printf '[extend]\nuseDefault = true\n' >"$SUBJECT/external.toml"
ln -s "$SUBJECT/external.toml" "$SUBJECT/policy.toml"
commit
BASE_SHA=$(git -C "$SUBJECT" rev-parse HEAD)
GITHUB_EVENT_NAME=pull_request SCAN_MODE=full expect 2 'config extension escaping trusted base refused'
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
