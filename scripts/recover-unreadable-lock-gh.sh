#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Keep the canonical regen_lock function unchanged. Only bridge the official
# tool's documented delete-and-recreate operation for unreadable input in CI.
set -euo pipefail
real_gh=${RECOVERY_REAL_GH:?}
if [[ "$#" -ne 1 || "$1" != actions-lock ]]; then
  exec "$real_gh" "$@"
fi

lock=.github/workflows/actions.lock
[[ -f "$lock" && ! -L "$lock" ]] || exit 2
before=$(sha256sum "$lock" | cut -d ' ' -f1)
[[ "$before" == "${RECOVERY_ORIGINAL_LOCK_SHA256:?}" ]] || exit 2
log=${RECOVERY_OUTPUT:?}/generator-first-attempt.log
rc=0
"$real_gh" actions-lock > "$log" 2>&1 || rc=$?
cat "$log" >&2
[[ "$rc" -ne 0 ]] || exit 0

# This exact recovery diagnostic is from gh-actions-lock v0.2.0's
# lockrecovery.go. Network/authentication/tool errors never trigger deletion.
if [[ "$rc" -ne 2 ]] || ! grep -Fq \
  'delete it and re-run to recreate it, or fix it by hand' "$log"; then
  exit "$rc"
fi
[[ $(sha256sum "$lock" | cut -d ' ' -f1) == "$before" ]] || exit 2
[[ -z $(git status --porcelain --untracked-files=all) ]] || exit 2

# Confirm the failure independently through the offline parser. It cannot
# mistake an API/permission failure for an unreadable local lock.
probe=${RECOVERY_OUTPUT}/unreadable-lock-probe.log
probe_rc=0
"$real_gh" actions-lock --verify-local > "$probe" 2>&1 || probe_rc=$?
cat "$probe" >&2
# v0.2.0 runVerifyLocal wraps LoadState errors with this exact prefix; it
# performs no network requests and never routes through interactive recovery.
[[ "$probe_rc" -eq 2 ]] && grep -Fq 'opening lockfile:' "$probe" || exit 2
[[ $(sha256sum "$lock" | cut -d ' ' -f1) == "$before" ]] || exit 2
[[ -z $(git status --porcelain --untracked-files=all) ]] || exit 2

# The outer canonical regen_lock already retained this original as --prior.
# Keep a separate byte-for-byte artifact too. Only the disposable subject
# checkout loses the unreadable file; no committed workflow is altered.
cmp -- "$lock" "${RECOVERY_OUTPUT}/original-actions.lock" || exit 2
rm -- "$lock"
echo 'Official tool confirmed unreadable input; recreating the whole lock in the disposable checkout.' >&2
"$real_gh" actions-lock
