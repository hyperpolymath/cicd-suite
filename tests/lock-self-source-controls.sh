#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Exercise the real closure guard in disposable Git repositories. The lock
# fixtures are the minimal shape read by that guard, not native-tool receipts.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
command -v git >/dev/null || { echo 'git is required' >&2; exit 2; }
command -v yq >/dev/null || { echo 'mikefarah yq v4 is required' >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
canonical=hyperpolymath/proven-cicd
legacy=hyperpolymath/cicd-suite
remote=actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
missing=0000000000000000000000000000000000000000
cases=0
fixtures=0
fixture=
pin=

commit_fixture() {
    git -C "$fixture" add .
    git -C "$fixture" -c core.hooksPath=/dev/null -c commit.gpgsign=false \
        -c user.name='CI control' -c user.email='ci-control@example.invalid' \
        commit -qm "$1"
}
new_fixture() {
    fixtures=$((fixtures + 1))
    fixture="$tmp/case-$fixtures"
    mkdir -p "$fixture/tests" "$fixture/actions/probe" "$fixture/.github/workflows"
    cp "$root/tests/lock-transitive-closure.sh" "$fixture/tests/"
    git init -q "$fixture"
    cat > "$fixture/actions/probe/action.yml" <<YAML
name: Probe
runs:
  using: composite
  steps:
    - uses: $remote
YAML
    cat > "$fixture/.github/workflows/probe.yml" <<'YAML'
name: Local composite
jobs:
  probe:
    runs-on: ubuntu-24.04
    steps:
      - uses: $/actions/probe
YAML
    cat > "$fixture/.github/workflows/actions.lock" <<YAML
version: v0.0.3
dependencies:
  $remote:
    commit: sha1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
workflows:
  .github/workflows/probe.yml:
    - $remote
YAML
    commit_fixture 'source fixture'
    pin=$(git -C "$fixture" rev-parse HEAD)
}
literal_pin() {
    local repository=$1 target=$2
    cat > "$fixture/.github/workflows/self.yml" <<YAML
name: Remote composite
jobs:
  probe:
    runs-on: ubuntu-24.04
    steps:
      - uses: $repository/actions/probe@$target
YAML
}
branch_pin() {
    local repository=$1 target=$2
    ref="$repository@main" target="sha1-$target" \
        yq -i '.dependencies[strenv(ref)].commit = strenv(target)' \
        "$fixture/.github/workflows/actions.lock"
}
expect() {
    local status=$1 repository=$2 label=$3 message=$4 actual=0
    GITHUB_REPOSITORY="$repository" bash "$fixture/tests/lock-transitive-closure.sh" \
        > "$tmp/log" 2>&1 || actual=$?
    if [[ "$actual" -ne "$status" ]] || ! grep -Fq -- "$message" "$tmp/log"; then
        cat "$tmp/log"
        printf 'FAIL %s: expected status %s and diagnostic %s; got %s\n' \
            "$label" "$status" "$message" "$actual" >&2
        exit 1
    fi
    if [[ "$status" -eq 0 ]] && ! grep -Eq '^PASS=[1-9][0-9]* FAIL=0$' "$tmp/log"; then
        cat "$tmp/log"
        echo "FAIL $label: no nonempty successful guard result" >&2
        exit 1
    fi
    cases=$((cases + 1))
    printf 'ok: %s\n' "$label"
}

# Each checkout name must inspect both exact source coordinates.
for checkout in "$canonical" "$legacy"; do
    for source in "$canonical" "$legacy"; do
        new_fixture
        literal_pin "$source" "$pin"
        expect 0 "$checkout" "$checkout checks literal $source" \
            'examined 1 self-referencing pin(s)'
    done
done
for checkout in "$canonical" "$legacy"; do
    new_fixture
    source=$legacy
    [[ "$checkout" != "$legacy" ]] || source=$canonical
    branch_pin "$source" "$pin"
    expect 0 "$checkout" "$checkout checks locked branch $source" \
        'serves the current actions/ tree'
done

new_fixture
literal_pin "$legacy" "$pin"
printf '      - uses: %s/actions/probe@%s\n' "$canonical" "$pin" \
    >> "$fixture/.github/workflows/self.yml"
expect 0 "$canonical" 'both names are examined, not collapsed into one unchecked pin' \
    'examined 2 self-referencing pin(s)'

# An unrelated checkout retains its own exact self identity, not suite aliases.
new_fixture
literal_pin 'example/fork' "$pin"
expect 0 'example/fork' 'unrelated checkout keeps exact self-reference checks' \
    'examined 1 self-referencing pin(s)'
for source in example/proven-cicd hyperpolymath/proven-cicd-extra hyperpolymath.extra/proven-cicd; do
    new_fixture
    literal_pin "$source" "$pin"
    expect 1 "$canonical" "unadmitted literal $source cannot supply a population" \
        'no self-referencing pin examined'
done
new_fixture
literal_pin "$canonical" "$pin"
expect 1 'example/fork' 'a fork does not inherit the suite alias family' \
    'no self-referencing pin examined'
new_fixture
branch_pin example/proven-cicd "$pin"
expect 1 "$canonical" 'unadmitted locked branch cannot supply a population' \
    'no self-referencing pin examined'

new_fixture
literal_pin "$legacy" "$missing"
expect 1 "$canonical" 'legacy literal still requires the pinned commit locally' \
    'which is not in this clone (need fetch-depth: 0)'
new_fixture
branch_pin "$canonical" "$missing"
expect 1 "$legacy" 'canonical locked branch still requires the pinned commit locally' \
    'which is not in this clone (need fetch-depth: 0)'

new_fixture
old=$pin
printf '# Changed source tree\n' >> "$fixture/actions/probe/action.yml"
commit_fixture 'changed composite'
current=$(git -C "$fixture" rev-parse HEAD)
literal_pin "$legacy" "$old"
printf '      - uses: %s/actions/probe@%s\n' "$canonical" "$current" \
    >> "$fixture/.github/workflows/self.yml"
expect 1 "$canonical" 'a current canonical pin cannot hide a stale legacy composite' \
    "which differs from HEAD's"
grep -Fq 'examined 2 self-referencing pin(s)' "$tmp/log"

new_fixture
old=$pin
printf '# Changed source tree\n' >> "$fixture/actions/probe/action.yml"
commit_fixture 'changed composite'
branch_pin "$canonical" "$old"
expect 1 "$legacy" 'canonical locked branch still requires the whole current actions tree' \
    'whose actions/ tree differs from HEAD'

new_fixture
expect 1 "$canonical" 'absence of either self-reference population is a refusal' \
    'no self-referencing pin examined'

new_fixture
literal_pin "$legacy" "$pin"
yq -i '.workflows[".github/workflows/probe.yml"] = []' \
    "$fixture/.github/workflows/actions.lock"
expect 1 "$canonical" 'alias admission does not waive transitive declarations' \
    'through a composite but does not declare it'

new_fixture
literal_pin "$legacy" "$pin"
ref="$remote" yq -i 'del(.dependencies[strenv(ref)])' \
    "$fixture/.github/workflows/actions.lock"
expect 1 "$canonical" 'alias admission does not waive dependency entries' \
    'but dependencies: has no such key'

[[ "$cases" -eq 20 ]] || { echo "Expected 20 controls, got $cases" >&2; exit 1; }
printf 'lock self-source controls: %s passed\n' "$cases"
