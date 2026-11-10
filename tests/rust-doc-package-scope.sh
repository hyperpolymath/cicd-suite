#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/good/src" "$work/optional/src"
printf '[workspace]\nmembers=["good","optional"]\nresolver="2"\n' > "$work/Cargo.toml"
for package in good optional; do
  printf '[package]\nname="%s"\nversion="0.1.0"\nedition="2021"\n' "$package" > "$work/$package/Cargo.toml"
done
printf '/// ```\n/// assert_eq!(2 + 2, 4);\n/// ```\npub fn good() {}\n' > "$work/good/src/lib.rs"
printf 'compile_error!("optional package needs another platform");\n' > "$work/optional/src/lib.rs"
(cd "$work" && cargo generate-lockfile --offline)
for phase in doc test; do
  WORKING_DIRECTORY="$work" RUST_GATE_PHASE="$phase" DOC_PACKAGES="-p good" TEST_ARGS="-p good" \
    bash --noprofile --norc -e -o pipefail "$root/actions/rust-ci-check/check.sh"
  if WORKING_DIRECTORY="$work" RUST_GATE_PHASE="$phase" TEST_ARGS="-p good" \
    bash --noprofile --norc -e -o pipefail "$root/actions/rust-ci-check/check.sh" >"$work/default.log" 2>&1; then
    echo "default workspace scope incorrectly accepted the broken package" >&2; exit 1
  fi
done
printf '/// ```\n/// assert_eq!(2 + 2, 5);\n/// ```\npub fn good() {}\n' > "$work/good/src/lib.rs"
if WORKING_DIRECTORY="$work" RUST_GATE_PHASE=test DOC_PACKAGES="-p good" TEST_ARGS="-p good" \
  bash --noprofile --norc -e -o pipefail "$root/actions/rust-ci-check/check.sh" >"$work/negative.log" 2>&1; then
  echo "selected package doctest failure was hidden" >&2; exit 1
fi
echo "Rust package scope positive, default-scope and failing-doctest controls passed."
