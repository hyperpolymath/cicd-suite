#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/gh" <<'MOCK'
#!/usr/bin/env bash
[[ ${GH_ERROR:-0} == 0 ]] || { echo '403 probe denied' >&2; exit 1; }
cat "$GH_FIXTURE"
MOCK
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" GH_FIXTURE="$tmp/fixture.json"
export SUBJECT_REPOSITORY=owner/repo SUBJECT_SHA=0123456789abcdef0123456789abcdef01234567 MAX_WAIT_SECONDS=0 GITHUB_OUTPUT="$tmp/output"
jq -n --arg sha "$SUBJECT_SHA" '{check_runs:[{id:10,name:"SonarCloud Code Analysis",head_sha:$sha,app:{id:12526,slug:"sonarqubecloud"},status:"completed",conclusion:"success",started_at:"2026-10-30T10:00:00Z"}]}' > "$tmp/base.json"
assert_case() {
    local label=$1 expected=$2 filter=$3 rc=0
    jq "$filter" "$tmp/base.json" > "$GH_FIXTURE"
    : > "$GITHUB_OUTPUT"
    bash "$root/actions/sonarcloud-result-check/check.sh" > "$tmp/log" 2>&1 || rc=$?
    [[ $rc == "$expected" ]] || { cat "$tmp/log"; echo "FAIL $label: wanted $expected got $rc"; exit 1; }
    [[ $rc != 2 || ! -s $GITHUB_OUTPUT ]] || { echo 'unverified result emitted a receipt'; exit 1; }
    echo "ok: $label"
}
assert_case 'official same-commit success' 0 '.'
grep -qx 'check-run-id=10' "$GITHUB_OUTPUT"
assert_case 'official failure remains failing' 1 '.check_runs[0].conclusion="failure"'
assert_case 'same name from another app refused' 2 '.check_runs[0].app.id=15368'
assert_case 'unexpected publisher slug refused' 2 '.check_runs[0].app.slug="another-app"'
assert_case 'wrong commit refused' 2 '.check_runs[0].head_sha="ffffffffffffffffffffffffffffffffffffffff"'
assert_case 'wrong check name refused' 2 '.check_runs[0].name="SonarQube"'
assert_case 'absent analysis is not a pass' 2 '.check_runs=[]'
assert_case 'pending analysis is not a pass' 2 '.check_runs[0] |= (.status="in_progress" | .conclusion=null)'
for conclusion in skipped neutral cancelled timed_out stale; do
    assert_case "$conclusion is not a completed quality verdict" 2 ".check_runs[0].conclusion=\"$conclusion\""
done
assert_case 'old success does not mask a newer pending rerun' 2 '.check_runs += [(.check_runs[0] | .id=11 | .started_at="2026-10-30T11:00:00Z" | .status="in_progress" | .conclusion=null)]'
assert_case 'new queued run with no start time supersedes old success' 2 '.check_runs += [(.check_runs[0] | .id=11 | .started_at=null | .status="queued" | .conclusion=null)]'
assert_case 'older run starting late cannot override newer failure' 1 '.check_runs[0].started_at="2026-10-30T12:00:00Z" | .check_runs += [(.check_runs[0] | .id=11 | .started_at="2026-10-30T11:00:00Z" | .conclusion="failure")]'
assert_case 'old success does not mask newer failure' 1 '.check_runs += [(.check_runs[0] | .id=11 | .started_at="2026-10-30T11:00:00Z" | .conclusion="failure")]'
assert_case 'official result on second API page is read' 0 '(.check_runs[0].app.id=15368), .'
assert_case 'malformed check-run population refused' 2 '.check_runs={}'
assert_case 'missing check ID refused' 2 'del(.check_runs[0].id)'
GH_ERROR=1 assert_case 'denied API is not absence or success' 2 '.'
MAX_WAIT_SECONDS=301 assert_case 'unbounded wait refused' 2 '.'
SUBJECT_SHA=main assert_case 'moving ref refused' 2 '.'
