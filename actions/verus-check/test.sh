#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf '// fixture\n' >"$work/subject.rs"
cat >"$work/oracle" <<'SH'
#!/usr/bin/env bash
case "${MODE:-good}" in
  accept) echo 'verification results:: 1 verified, 0 errors'; exit 0 ;;
  reject) exit 1 ;;
esac
case "${!#}" in *negative.rs) exit 1 ;; esac
case "${MODE:-good}" in
  empty) echo 'verification results:: 0 verified, 0 errors' ;;
  subject-fails) case "${!#}" in *subject.rs) exit 1 ;; esac; echo 'verification results:: 1 verified, 0 errors' ;;
  *) echo 'verification results:: 1 verified, 0 errors' ;;
esac
SH
chmod +x "$work/oracle"
for mode in good accept reject empty subject-fails; do
  status=0
  MODE="$mode" VERUS="$work/oracle" bash "$here/check.sh" "$work/subject.rs" >"$work/out" 2>&1 || status=$?
  case "$mode" in good) expected=0 ;; subject-fails) expected=1 ;; *) expected=2 ;; esac
  [[ "$status" -eq "$expected" ]] || { cat "$work/out"; echo "$mode: expected $expected, got $status"; exit 1; }
done
status=0
VERUS="$work/oracle" bash "$here/check.sh" >"$work/out" 2>&1 || status=$?
[[ "$status" -eq 2 ]]
echo 'Verus gate controls: 6 passed'
