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

for repo in untrusted/hypatia hyperpolymath/other; do
  rc=0
  SUBJECT_REPOSITORY=$repo SUBJECT_SHA=0123456789abcdef0123456789abcdef01234567 \
    SUBJECT_DIR="$tmp/fixture" AUTHORITY_DIR="$tmp/authority" RECOVERY_OUTPUT="$tmp/output" RUNNER_TEMP=$tmp \
    bash "$root/scripts/generate-lock-recovery-candidate.sh" > "$tmp/log" 2>&1 || rc=$?
  [[ "$rc" -eq 2 ]]
done
echo 'ok: candidate generator refuses other repositories'
