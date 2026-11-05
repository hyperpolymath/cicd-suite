#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Boundary controls only. The workflow separately runs the real official tool.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir "$tmp/fixture" "$tmp/output"
git init -q "$tmp/fixture"
mkdir -p "$tmp/fixture/.github/workflows"
printf 'unreadable-original-lock\n' > "$tmp/fixture/.github/workflows/actions.lock"
printf 'name: Preserved\njobs: {}\n' > "$tmp/fixture/.github/workflows/ci.yml"
git -C "$tmp/fixture" add .github
git -C "$tmp/fixture" -c user.name='CI control' -c user.email='ci-control@example.invalid' commit -qm 'immutable recovery subject fixture'
cat > "$tmp/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CALL_LOG"
if [[ "$1" != actions-lock ]]; then exit 0; fi
if [[ "${2:-}" == --verify-local ]]; then
  if [[ "$MODE" == offline-error ]]; then echo 'authentication failed' >&2; exit 2; fi
  echo 'opening lockfile: invalid lock' >&2
  exit 2
fi
case "$MODE" in
  success) exit 0 ;;
  auth-error) echo 'authentication failed' >&2; exit 2 ;;
esac
if [[ -f .github/workflows/actions.lock ]]; then
  if [[ "$MODE" == mutation ]]; then printf 'unexpected workflow edit\n' >> .github/workflows/ci.yml; fi
  echo 'invalid lock; delete it and re-run to recreate it, or fix it by hand' >&2
  exit 2
fi
printf 'official-generator-fixture\n' > .github/workflows/actions.lock
MOCK
chmod +x "$tmp/gh"
export RECOVERY_REAL_GH="$tmp/gh" RECOVERY_OUTPUT="$tmp/output" CALL_LOG="$tmp/calls"
export RECOVERY_ORIGINAL_LOCK_SHA256
RECOVERY_ORIGINAL_LOCK_SHA256=$(sha256sum "$tmp/fixture/.github/workflows/actions.lock" | cut -d ' ' -f1)

for mode in success auth-error offline-error mutation unreadable; do
  git -C "$tmp/fixture" reset --hard -q HEAD
  cp "$tmp/fixture/.github/workflows/actions.lock" "$tmp/output/original-actions.lock"
  : > "$CALL_LOG"
  rc=0
  (cd "$tmp/fixture" && MODE=$mode bash "$root/scripts/recover-unreadable-lock-gh.sh" actions-lock) > "$tmp/log" 2>&1 || rc=$?
  case "$mode" in
    success)
      [[ "$rc" -eq 0 && $(wc -l < "$CALL_LOG") -eq 1 ]]
      cmp "$tmp/fixture/.github/workflows/actions.lock" "$tmp/output/original-actions.lock"
      ;;
    unreadable)
      [[ "$rc" -eq 0 && $(wc -l < "$CALL_LOG") -eq 3 ]]
      grep -Fxq official-generator-fixture "$tmp/fixture/.github/workflows/actions.lock"
      git -C "$tmp/fixture" diff --quiet -- .github/workflows/ci.yml
      ;;
    *)
      [[ "$rc" -eq 2 ]]
      cmp "$tmp/fixture/.github/workflows/actions.lock" "$tmp/output/original-actions.lock"
      ;;
  esac
  echo "ok: recovery boundary $mode"
done
git -C "$tmp/fixture" reset --hard -q HEAD
: > "$CALL_LOG"
rc=0
(cd "$tmp/fixture" && RECOVERY_ORIGINAL_LOCK_SHA256=wrong MODE=unreadable \
  bash "$root/scripts/recover-unreadable-lock-gh.sh" actions-lock) > "$tmp/log" 2>&1 || rc=$?
[[ "$rc" -eq 2 && ! -s "$CALL_LOG" ]]
echo 'ok: wrong original digest is refused before invoking the tool'

for repo in '' untrusted/hypatia hyperpolymath/other hyperpolymath/boj-server hyperpolymath/boj-server-cartridges-extra untrusted/echidna hyperpolymath/echidna-extra untrusted/cicd-squabbler hyperpolymath/cicd-squabbler-extra hyperpolymath/squabbler untrusted/panic-attack hyperpolymath/panic-attack-extra hyperpolymath/panic-attacker; do
  rc=0
  SUBJECT_REPOSITORY=$repo SUBJECT_SHA=0123456789abcdef0123456789abcdef01234567 \
    SUBJECT_DIR="$tmp/fixture" AUTHORITY_DIR="$tmp/authority" RECOVERY_OUTPUT="$tmp/output" RUNNER_TEMP=$tmp \
    bash "$root/scripts/generate-lock-recovery-candidate.sh" > "$tmp/log" 2>&1 || rc=$?
  [[ "$rc" -eq 2 ]]
  grep -Fxq 'Recovery subject is outside the admitted repository scope' "$tmp/log"
done
echo 'ok: candidate generator refuses other repositories'

for repo in hyperpolymath/hypatia hyperpolymath/boj-server-cartridges hyperpolymath/echidna hyperpolymath/cicd-squabbler hyperpolymath/panic-attack; do
  rc=0
  SUBJECT_REPOSITORY=$repo SUBJECT_SHA=0123456789abcdef0123456789abcdef01234567 \
    SUBJECT_DIR="$tmp/fixture" AUTHORITY_DIR="$tmp/authority" RECOVERY_OUTPUT="$tmp/outside" RUNNER_TEMP="$tmp/runner" \
    bash "$root/scripts/generate-lock-recovery-candidate.sh" > "$tmp/log" 2>&1 || rc=$?
  [[ "$rc" -eq 2 ]]
  grep -Fxq 'Recovery output must be in the disposable runner directory' "$tmp/log"
  echo "ok: candidate generator admits $repo only as far as the next independent boundary"
  for bad_sha in main v0.2.0 0123456789abcdef ABCDEF0123456789ABCDEF0123456789ABCDEF0123 0123456789abcdef0123456789abcdef01234567extra; do
    rc=0
    SUBJECT_REPOSITORY=$repo SUBJECT_SHA=$bad_sha \
      SUBJECT_DIR="$tmp/fixture" AUTHORITY_DIR="$tmp/authority" RECOVERY_OUTPUT="$tmp/output" RUNNER_TEMP=$tmp \
      bash "$root/scripts/generate-lock-recovery-candidate.sh" > "$tmp/log" 2>&1 || rc=$?
    [[ "$rc" -eq 2 ]]
    grep -Fxq 'Recovery subject is outside the admitted repository/revision scope' "$tmp/log"
  done
done
echo 'ok: candidate generator refuses floating, partial and malformed revisions for all five repositories'

# Execute the workflow's actual data-transfer blocks against local Git
# fixtures. Source scripts and Git hooks are data, never commands to run.
command -v yq >/dev/null || { echo 'yq unavailable for transfer controls'; exit 2; }
workflow="$root/.github/workflows/actions-lock-recovery.yml"
yq -o=json '.on.workflow_dispatch.inputs.repo' "$workflow" | jq -e '
  .type == "choice" and .required == true and .default == "hyperpolymath/hypatia" and
  .options == ["hyperpolymath/hypatia", "hyperpolymath/boj-server-cartridges", "hyperpolymath/echidna", "hyperpolymath/cicd-squabbler", "hyperpolymath/panic-attack"]' >/dev/null
yq -r '.jobs."acquire-subject".steps[] | select(.id == "subject") | .run' "$workflow" > "$tmp/admit.sh"
[[ -s "$tmp/admit.sh" ]] || exit 2
export GITHUB_OUTPUT="$tmp/subject-outputs"
valid_sha=0123456789abcdef0123456789abcdef01234567
for repo in hyperpolymath/hypatia hyperpolymath/boj-server-cartridges hyperpolymath/echidna hyperpolymath/cicd-squabbler hyperpolymath/panic-attack; do
  : > "$GITHUB_OUTPUT"
  EVENT=workflow_dispatch REQUESTED_REPO=$repo REQUESTED_SHA=$valid_sha bash "$tmp/admit.sh"
  printf 'repository=%s\nsha=%s\n' "$repo" "$valid_sha" > "$tmp/expected-outputs"
  cmp "$tmp/expected-outputs" "$GITHUB_OUTPUT"
  echo "ok: workflow admission binds the exact $repo and SHA outputs"
done
: > "$GITHUB_OUTPUT"
EVENT=push REQUESTED_REPO=untrusted/ignored REQUESTED_SHA=main bash "$tmp/admit.sh"
printf 'repository=hyperpolymath/hypatia\nsha=936196794e0266715e7b1902893cdcbca64ef73a\n' > "$tmp/expected-outputs"
cmp "$tmp/expected-outputs" "$GITHUB_OUTPUT"
echo 'ok: the push subject remains the fixed Hypatia revision'
for repo in '' untrusted/hypatia hyperpolymath/boj-server hyperpolymath/boj-server-cartridges-extra untrusted/echidna hyperpolymath/echidna-extra untrusted/cicd-squabbler hyperpolymath/cicd-squabbler-extra hyperpolymath/squabbler untrusted/panic-attack hyperpolymath/panic-attack-extra hyperpolymath/panic-attacker; do
  : > "$GITHUB_OUTPUT"
  rc=0
  EVENT=workflow_dispatch REQUESTED_REPO=$repo REQUESTED_SHA=$valid_sha bash "$tmp/admit.sh" > "$tmp/log" 2>&1 || rc=$?
  [[ "$rc" -eq 2 && ! -s "$GITHUB_OUTPUT" ]]
  grep -Fxq 'Repository is outside this recovery scope' "$tmp/log"
done
echo 'ok: workflow admission refuses absent, other-owner and similarly named repositories'
for repo in hyperpolymath/hypatia hyperpolymath/boj-server-cartridges hyperpolymath/echidna hyperpolymath/cicd-squabbler hyperpolymath/panic-attack; do
  for bad_sha in '' main v0.2.0 0123456789abcdef ABCDEF0123456789ABCDEF0123456789ABCDEF0123 0123456789abcdef0123456789abcdef01234567extra; do
    : > "$GITHUB_OUTPUT"
    rc=0
    EVENT=workflow_dispatch REQUESTED_REPO=$repo REQUESTED_SHA=$bad_sha bash "$tmp/admit.sh" > "$tmp/log" 2>&1 || rc=$?
    [[ "$rc" -eq 2 && ! -s "$GITHUB_OUTPUT" ]]
    grep -Fxq 'An exact subject SHA is required' "$tmp/log"
  done
done
echo 'ok: workflow admission refuses missing, floating, partial and malformed revisions for all five repositories'
yq -r '.jobs."acquire-subject".steps[] | select(.id == "archive") | .run' "$workflow" > "$tmp/package.sh"
yq -r '.jobs.candidate.steps[] | select(.name == "Verify and unpack the subject data") | .run' "$workflow" > "$tmp/unpack.sh"
[[ -s "$tmp/package.sh" && -s "$tmp/unpack.sh" ]] || exit 2
mkdir -p "$tmp/acquisition" "$tmp/transfer/recovery-subject-data" "$tmp/consumer"
git clone --quiet --no-local "$tmp/fixture" "$tmp/acquisition/subject"
printf '#!/usr/bin/env bash\ntouch "%s"\n' "$tmp/executed-source" > "$tmp/acquisition/subject/subject-script.sh"
git -C "$tmp/acquisition/subject" add subject-script.sh
git -C "$tmp/acquisition/subject" -c user.name='CI control' -c user.email='ci-control@example.invalid' commit -qm 'non-executed source payload'
subject_sha=$(git -C "$tmp/acquisition/subject" rev-parse HEAD)
printf '#!/usr/bin/env bash\ntouch "%s"\n' "$tmp/executed-hook" > "$tmp/acquisition/subject/.git/hooks/post-checkout"
chmod +x "$tmp/acquisition/subject/.git/hooks/post-checkout"
export RUNNER_TEMP="$tmp/transfer" GITHUB_OUTPUT="$tmp/transfer-outputs"
: > "$GITHUB_OUTPUT"
(cd "$tmp/acquisition" && EXPECTED_SHA=$subject_sha bash "$tmp/package.sh")
[[ ! -e "$tmp/executed-source" && ! -e "$tmp/executed-hook" ]]
tar -tzf "$RUNNER_TEMP/subject.tar.gz" > "$tmp/archive-paths"
! grep -q '^./.git/hooks' "$tmp/archive-paths"
cp "$RUNNER_TEMP/subject.tar.gz" "$RUNNER_TEMP/recovery-subject-data/subject.tar.gz"
archive_sha=$(sha256sum "$RUNNER_TEMP/subject.tar.gz" | cut -d ' ' -f1)
(cd "$tmp/consumer" && EXPECTED_ARCHIVE_SHA256=$archive_sha bash "$tmp/unpack.sh")
[[ $(git -C "$tmp/consumer/subject" rev-parse HEAD) == "$subject_sha" ]]
[[ ! -e "$tmp/consumer/subject/.git/hooks" && ! -e "$tmp/executed-source" && ! -e "$tmp/executed-hook" ]]
echo 'ok: same-run archive preserves exact source and excludes Git hooks without executing either'

rc=0
(cd "$tmp/acquisition" && EXPECTED_SHA=0000000000000000000000000000000000000000 bash "$tmp/package.sh") > "$tmp/log" 2>&1 || rc=$?
[[ "$rc" -eq 2 ]]
echo 'ok: acquisition refuses a mismatched subject SHA'
git -C "$tmp/acquisition/subject" config http.https://github.com/.extraheader 'synthetic-credential-fixture'
rc=0
(cd "$tmp/acquisition" && EXPECTED_SHA=$subject_sha bash "$tmp/package.sh") > "$tmp/log" 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] && grep -Fq 'Checkout credentials must not enter' "$tmp/log"
! grep -Fq synthetic-credential-fixture "$tmp/log"
git -C "$tmp/acquisition/subject" config --unset http.https://github.com/.extraheader
echo 'ok: acquisition refuses credential metadata without printing its value'
ln -s /outside-subject "$tmp/acquisition/subject/external-link"
git -C "$tmp/acquisition/subject" add external-link
git -C "$tmp/acquisition/subject" -c user.name='CI control' -c user.email='ci-control@example.invalid' commit -qm 'unsafe symbolic link fixture'
rc=0
(cd "$tmp/acquisition" && EXPECTED_SHA=$(git -C subject rev-parse HEAD) bash "$tmp/package.sh") > "$tmp/log" 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] && grep -Fq 'Non-regular source objects require separate recovery review' "$tmp/log"
echo 'ok: acquisition refuses source symlinks before archive transfer'
mkdir "$tmp/tampered-consumer"
printf 'tampered archive' >> "$RUNNER_TEMP/recovery-subject-data/subject.tar.gz"
rc=0
(cd "$tmp/tampered-consumer" && EXPECTED_ARCHIVE_SHA256=$archive_sha bash "$tmp/unpack.sh") > "$tmp/log" 2>&1 || rc=$?
[[ "$rc" -eq 2 && ! -e "$tmp/tampered-consumer/subject" ]]
echo 'ok: consumer refuses a changed archive before extraction'

# A binary claiming the expected version still has to match the committed
# release digest before it becomes executable or reaches gh registration.
mkdir "$tmp/tool-install-mocks" "$tmp/tool-install-temp"
printf '#!/usr/bin/env bash\nprintf executed > "%s"\nprintf "actions-lock version v0.2.0\\n"\n' \
  "$tmp/unverified-executed" > "$tmp/unverified-binary"
cat > "$tmp/tool-install-mocks/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
: > "$INSTALL_CURL_CALLED"
[[ ${INSTALL_DOWNLOAD_MODE:-copy} != fail ]] || exit 22
output=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output=$2; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$output" ]] || exit 99
cp -- "$INSTALL_MOCK_ARTIFACT" "$output"
MOCK
cat > "$tmp/tool-install-mocks/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
: > "$INSTALL_GH_CALLED"
[[ ! -x ./gh-actions-lock ]] || ./gh-actions-lock --version
MOCK
chmod +x "$tmp/tool-install-mocks/curl" "$tmp/tool-install-mocks/gh"
export INSTALL_CURL_CALLED="$tmp/install-curl-called" INSTALL_GH_CALLED="$tmp/install-gh-called"
export INSTALL_MOCK_ARTIFACT="$tmp/unverified-binary"
for mode in copy fail; do
  : > "$tmp/install-env"
  rm -f "$INSTALL_CURL_CALLED" "$INSTALL_GH_CALLED" "$tmp/unverified-executed"
  rc=0
  env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN \
    PATH="$tmp/tool-install-mocks:$PATH" RUNNER_TEMP="$tmp/tool-install-temp" GITHUB_ENV="$tmp/install-env" \
    INSTALL_DOWNLOAD_MODE=$mode bash "$root/scripts/install-lock-recovery-tool.sh" > "$tmp/log" 2>&1 || rc=$?
  [[ "$rc" -eq 2 && -e "$INSTALL_CURL_CALLED" && ! -e "$INSTALL_GH_CALLED" && ! -e "$tmp/unverified-executed" && ! -s "$tmp/install-env" ]]
  if [[ "$mode" == copy ]]; then
    grep -Fxq 'Recovery binary identity mismatch; no downloaded code was executed' "$tmp/log"
    echo 'ok: an unverified binary is refused before execution or gh registration despite its version claim'
  else
    grep -Fxq 'Official recovery binary download failed' "$tmp/log"
    echo 'ok: download failure does not register or execute a recovery tool'
  fi
done
rm -f "$INSTALL_CURL_CALLED" "$INSTALL_GH_CALLED"
rc=0
env -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN \
  GH_TOKEN=credential-fixture PATH="$tmp/tool-install-mocks:$PATH" \
  RUNNER_TEMP="$tmp/tool-install-temp" GITHUB_ENV="$tmp/install-env" \
  bash "$root/scripts/install-lock-recovery-tool.sh" > "$tmp/log" 2>&1 || rc=$?
[[ "$rc" -eq 2 && ! -e "$INSTALL_CURL_CALLED" && ! -e "$INSTALL_GH_CALLED" && ! -s "$tmp/install-env" ]]
grep -Fxq 'Recovery tool installation must run without GitHub credentials' "$tmp/log"
! grep -Fq credential-fixture "$tmp/log"
echo 'ok: installation refuses token-bearing execution before download without printing the token'
