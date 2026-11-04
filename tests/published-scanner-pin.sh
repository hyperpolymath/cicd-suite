#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/gh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PROBE_LOG"
[[ "$1" == api && "$2" == "repos/$EXPECTED_REPOSITORY/compare/$EXPECTED_PIN...main" && "$3" == --jq && "$4" == .status ]] || exit 99
[[ ${PROBE_FAILURE:-0} == 0 ]] || exit 1
echo "${COMPARISON-identical}"
MOCK
chmod +x "$tmp/gh"
export PATH="$tmp:$PATH"
pin=0123456789abcdef0123456789abcdef01234567
export EXPECTED_PIN=$pin PROBE_LOG="$tmp/probe-log"
for repository in hyperpolymath/cicd-suite hyperpolymath/proven-cicd; do
  export EXPECTED_REPOSITORY=$repository
  for status in identical ahead behind diverged null unknown ''; do
    rc=0
    COMPARISON=$status bash "$root/scripts/verify-published-scanner-pin.sh" "$pin" "$repository" >"$tmp/out" 2>&1 || rc=$?
    case $status in
        identical|ahead) [[ $rc == 0 ]] ;;
        behind|diverged) [[ $rc == 1 ]] ;;
        *) [[ $rc == 2 ]] ;;
    esac
    echo "ok: publication guard handles $repository ($status)"
  done
  rc=0
  PROBE_FAILURE=1 bash "$root/scripts/verify-published-scanner-pin.sh" "$pin" "$repository" >"$tmp/out" 2>&1 || rc=$?
  [[ $rc == 2 ]]
done
export EXPECTED_REPOSITORY=hyperpolymath/cicd-suite
bash "$root/scripts/verify-published-scanner-pin.sh" "$pin" >/dev/null
for repository in attacker/proven-cicd hyperpolymath/proven-cicd-extra ''; do
  : > "$PROBE_LOG"
  rc=0
  bash "$root/scripts/verify-published-scanner-pin.sh" "$pin" "$repository" >"$tmp/out" 2>&1 || rc=$?
  [[ $rc == 2 && ! -s "$PROBE_LOG" ]]
done
rc=0
bash "$root/scripts/verify-published-scanner-pin.sh" main >"$tmp/out" 2>&1 || rc=$?
[[ $rc == 2 ]]
echo 'ok: publication guard refuses unavailable evidence and non-SHA refs'
