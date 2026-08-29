#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

checker="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check.sh"
readonly checker
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
git -C "$fixture" init -q
git -C "$fixture" config user.email test@example.invalid
git -C "$fixture" config user.name 'Hygiene test'
mkdir -p "$fixture/src" "$fixture/docs" "$fixture/.github/workflows" \
  "$fixture/.machine_readable/templates"

printf '%s\n' '// clean source' > "$fixture/src/main.rs"
printf '%s\n' 'TODO in documentation is explanatory.' > "$fixture/docs/design.md"
printf '%s\n' '# TODO: workflow follow-up' > "$fixture/.github/workflows/ci.yml"
printf '%s\n' 'TODO: fill this template' > "$fixture/.machine_readable/templates/example.ncl"
git -C "$fixture" add .
git -C "$fixture" commit -qm fixture

(cd "$fixture" && bash "$checker")

printf '%s\n' '// TODO: untracked implementation debt' > "$fixture/src/main.rs"
if (cd "$fixture" && bash "$checker"); then
  echo 'FAIL: untracked source debt was accepted' >&2
  exit 1
fi

printf '%s\n' '// TODO(#123): tracked implementation debt' > "$fixture/src/main.rs"
(cd "$fixture" && bash "$checker")

printf '%s\n' 'proof = believe_me value' > "$fixture/src/Safety.idr"
if (cd "$fixture" && bash "$checker"); then
  echo 'FAIL: proof circumvention was accepted' >&2
  exit 1
fi

printf '%s\n' 'src/Safety.idr' > "$fixture/.cicd-hygiene-allow"
(cd "$fixture" && bash "$checker")
echo 'All code-hygiene positive and negative controls passed.'
