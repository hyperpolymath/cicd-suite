#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/gh" <<'MOCK'
#!/usr/bin/env bash
[[ ${PROBE_FAILURE:-0} == 0 ]] || exit 1
echo "${COMPARISON:-identical}"
MOCK
chmod +x "$tmp/gh"
export PATH="$tmp:$PATH"
pin=0123456789abcdef0123456789abcdef01234567
for status in identical ahead behind diverged; do
    rc=0
    COMPARISON=$status bash "$root/scripts/verify-published-scanner-pin.sh" "$pin" >"$tmp/out" 2>&1 || rc=$?
    case $status in
        identical|ahead) [[ $rc == 0 ]] ;;
        *) [[ $rc == 1 ]] ;;
    esac
    echo "ok: publication guard handles $status"
done
rc=0
PROBE_FAILURE=1 bash "$root/scripts/verify-published-scanner-pin.sh" "$pin" >"$tmp/out" 2>&1 || rc=$?
[[ $rc == 2 ]]
rc=0
bash "$root/scripts/verify-published-scanner-pin.sh" main >"$tmp/out" 2>&1 || rc=$?
[[ $rc == 2 ]]
echo 'ok: publication guard refuses unavailable evidence and non-SHA refs'
