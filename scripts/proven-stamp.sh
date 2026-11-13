#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# proven-stamp.sh hash|stamp|check FILE
#
# The stamp is the first line of a stamped copy:
#   # proven-cicd: <artifact>@<version> sha256:<hex>
# The hash covers the HASHED REGION, meaning every line of the file except
#   * the stamp line itself, and
#   * each line that directly follows a line reading `# proven-cicd:local-next`
#     (after optional indentation). That is the LOCAL REGION: values that
#     legitimately differ per repository, such as the pinned suite SHA and the
#     third-party `uses:` SHAs that Dependabot moves. The marker sits on a line
#     of its own, so a Dependabot rewrite of the next line cannot disturb it.
#
#   hash   print the hashed-region sha256
#   stamp  rewrite the stamp line's hash to match the body (the file must
#          already start with a stamp line naming artifact and version)
#   check  exit 0 when the stamp matches the body, 1 on drift, 2 when the file
#          has no stamp or cannot be read
#
# The check detects edits only. Whoever edits the body can edit the stamp, so
# staleness (BEHIND) is judged by the applier against the published manifest,
# never by the copy itself.
set -euo pipefail

mode=${1:-} file=${2:-}
[[ -f $file ]] || { echo "proven-stamp: $file missing" >&2; exit 2; }
readonly stamp_re='^# proven-cicd: [A-Za-z0-9._-]+@[0-9]+\.[0-9]+\.[0-9]+ sha256:[0-9a-f]{64}$'

region() {
  awk 'NR == 1 && /^# proven-cicd: / { next }
       skip { skip = 0; next }
       /^[[:space:]]*# proven-cicd:local-next[[:space:]]*$/ { print; skip = 1; next }
       { print }' "$file"
}
digest() { region | sha256sum | cut -d' ' -f1; }

first=$(head -n 1 "$file")
case $mode in
  hash) digest ;;
  stamp)
    [[ $first =~ ^#\ proven-cicd:\ [A-Za-z0-9._-]+@[0-9]+\.[0-9]+\.[0-9]+\ sha256: ]] ||
      { echo "proven-stamp: $file does not start with a stamp line" >&2; exit 2; }
    h=$(digest)
    tmp=$(mktemp)
    { printf '%s\n' "${first%%sha256:*}sha256:$h"; tail -n +2 "$file"; } > "$tmp"
    cat "$tmp" > "$file"; rm -f -- "$tmp"
    echo "stamped $file sha256:$h" ;;
  check)
    [[ $first =~ $stamp_re ]] || { echo "proven-stamp: $file has no valid stamp line" >&2; exit 2; }
    want=${first##*sha256:} got=$(digest)
    if [[ $want == "$got" ]]; then echo "ok: $file matches its stamp"; exit 0; fi
    echo "DRIFT: $file body sha256:$got, stamp says sha256:$want" >&2
    exit 1 ;;
  *) echo "usage: proven-stamp.sh hash|stamp|check FILE" >&2; exit 2 ;;
esac
