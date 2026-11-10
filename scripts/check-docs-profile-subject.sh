#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Exact-commit document-presence observation. It is not a complete CI verdict.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[[ $# == 3 && -f $1 && -d $2 && $3 =~ ^[a-f0-9]{40}$ ]] || {
  echo 'usage: check-docs-profile-subject.sh PROFILE.json REPOSITORY_DIR EXPECTED_COMMIT' >&2; exit 2;
}
for tool in jq git realpath sha256sum mktemp; do
  command -v "$tool" >/dev/null || { echo "$tool required" >&2; exit 2; }
done
bash "$ROOT/scripts/validate-ci-profile.sh" "$1" >/dev/null
[[ $(jq -r .mother "$1") == docs-data-v1 ]] || { echo 'docs-data profile required' >&2; exit 1; }
coordinate=$(jq -r .repository "$1")
repo=$(realpath -e "$2")
[[ $(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) == "$repo" ]] || {
  echo 'repository root required' >&2; exit 1;
}
origin=$(git -C "$repo" remote get-url origin 2>/dev/null) || {
  echo 'repository origin unavailable' >&2; exit 1;
}
[[ $origin == "https://github.com/$coordinate" || $origin == "https://github.com/$coordinate.git" ]] || {
  echo 'profile repository differs from checkout origin' >&2; exit 1;
}
[[ $(git -C "$repo" rev-parse HEAD) == "$3" ]] || { echo 'wrong source commit' >&2; exit 1; }
git -C "$repo" diff --quiet HEAD -- || { echo 'checkout has changed tracked files' >&2; exit 1; }
root_slot=$(jq -r .slots.root "$1")
subject_root=$(realpath -e "$repo/$root_slot") || { echo 'document root absent' >&2; exit 1; }
[[ -d $subject_root && ( $subject_root == "$repo" || $subject_root == "$repo/"* ) ]] || {
  echo 'document root escapes repository' >&2; exit 1;
}
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
while IFS= read -r document; do
  path="$root_slot/$document"
  [[ $root_slot != . ]] || path=$document
  git -C "$repo" ls-files --error-unmatch -- "$path" >/dev/null 2>&1 || {
    echo "document is untracked or missing: $path" >&2; exit 1;
  }
  resolved=$(realpath -e "$subject_root/$document") || { echo "document absent: $path" >&2; exit 1; }
  [[ $resolved == "$subject_root/"* && -f $resolved && -s $resolved ]] || {
    echo "document empty or escapes root: $path" >&2; exit 1;
  }
  digest=$(sha256sum "$resolved")
  printf '%s\t%s\n' "$path" "${digest%% *}" >>"$tmp"
done < <(jq -r '.slots.documents[]' "$1")
jq -Rn --arg repository "$coordinate" --arg commit "$3" '
  {repository:$repository, commit:$commit, observation:"document-presence-passed",
   documents:[inputs | split("\t") | {path:.[0], sha256:.[1]}]}
' <"$tmp"
