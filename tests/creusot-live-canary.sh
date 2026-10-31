#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Prerequisite/absence controls only. A pass here is NOT a Creusot proof.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
command -v cargo >/dev/null || { echo 'real Cargo required' >&2; exit 2; }
yq --version | grep -q 'mikefarah/yq' || { echo 'mikefarah yq required' >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pin=hyperpolymath/cicd-suite/.github/workflows/creusot-gate.yml@6c6d772ebe82605ba22254db528faf54faec9f49

# Validate the bounded input and call contract. Every failure propagates even
# when this function is called in an `if` (where Bash suppresses errexit).
validate() {
    local tree=$1 fixture=$1/tests/fixtures/creusot-live
    echo "checking caller contract"
    yq -o=json '.' "$tree/.github/workflows/creusot-live-canary.yml" > "$tmp/workflow.json" || return 1
    jq -e --arg pin "$pin" '
      .permissions == {contents:"read"} and
      .jobs.creusot.uses == $pin and .jobs.creusot.needs == "fixture" and
      .jobs.creusot.with == {working_directory:"tests/fixtures/creusot-live",
        creusot_version:"0.14.0",rust_nightly:"nightly-2026-08-03",enforce_hollow:true}
    ' "$tmp/workflow.json" >/dev/null || return 1
    echo "checking lock, Why3find configuration and untrusted obligation"
    [[ -s $fixture/Cargo.lock ]] || return 1
    jq -e '.packages==["creusot"] and .provers==["z3"] and
      .tactics==["compute_specified","split_vc"]' "$fixture/why3find.json" >/dev/null || return 1
    # This is deliberately ONE fixed specimen, not a Rust syntax parser.
    # Refuse extra compilation inputs and exact-source changes, including
    # line/block-commented attributes. Growing it needs a reviewed boundary update.
    local sources
    sources=$(find "$fixture" -type d \( -name target -o -name _creusot_erasure -o -name verif -o -name .why3find \) -prune -o -type f -name '*.rs' -print) || return 1
    [[ $sources == "$fixture/src/lib.rs" && ! -L $fixture/src/lib.rs ]] || return 1
    [[ $(sha256sum "$fixture/src/lib.rs" | cut -d' ' -f1) == 4792ac10f2cfc09020d8bb5c7164d6368ab42a47db44214db031c911dd9d877a ]] || return 1
    # Fix the manifest too: it cannot silently acquire external targets or build scripts.
    [[ $(sha256sum "$fixture/Cargo.toml" | cut -d' ' -f1) == ab9522c2a92e0e2f41d56f4db12caf05f7a2fad33b4c625a191ebdca03c240bd ]] || return 1
    grep -Fq '#[ensures(result == x)]' "$fixture/src/lib.rs" || return 1
    if grep -Eq '#\[trusted([[:space:]]|\])' "$fixture/src/lib.rs"; then return 1; fi
    echo "checking Cargo manifest metadata"
    cargo metadata --locked --format-version 1 --manifest-path "$fixture/Cargo.toml" > "$tmp/metadata.json" || return 1
    jq -e '[.packages[] | select(.name=="cicd-suite-creusot-live" and .edition=="2024") |
      .dependencies[] | select(.name=="creusot-std" and .req=="=0.14.0")] | length==1' "$tmp/metadata.json" >/dev/null || return 1
}

# Copy only the fixture and caller into an isolated tree before each mutation.
stage() {
    rm -rf "$tmp/tree"
    mkdir -p "$tmp/tree/tests/fixtures" "$tmp/tree/.github/workflows"
    cp -a "$ROOT/tests/fixtures/creusot-live" "$tmp/tree/tests/fixtures/"
    cp "$ROOT/.github/workflows/creusot-live-canary.yml" "$tmp/tree/.github/workflows/"
}
# Never count a successful validation as rejection.
reject() {
    local label=$1
    if validate "$tmp/tree" > "$tmp/log" 2>&1; then
        echo "::error::accepted $label" >&2; exit 1
    fi
    echo "ok: rejected $label"
}
if ! validate "$ROOT" > "$tmp/baseline.log" 2>&1; then
    # Surface public prerequisite diagnostics through the Checks API as well
    # as runner logs; denied log-download access must not hide the failure.
    while IFS= read -r line; do
        line=${line//%/%25}
        echo "::error::live-canary prerequisite: $line" >&2
    done < "$tmp/baseline.log"
    exit 1
fi
cat "$tmp/baseline.log"
echo 'ok: configured, Cargo-locked fixture and published caller pin (not proof)'
stage
rm "$tmp/tree/tests/fixtures/creusot-live/why3find.json"
reject 'missing Why3find configuration'
stage
rm "$tmp/tree/tests/fixtures/creusot-live/Cargo.lock"
reject 'missing Cargo.lock'
stage
sed -i 's/6c6d772ebe82605ba22254db528faf54faec9f49/main/g' "$tmp/tree/.github/workflows/creusot-live-canary.yml"
reject 'floating gate pin'
stage
sed -i 's/creusot-std = "=0.14.0"/creusot-std = "=0.13.0"/' "$tmp/tree/tests/fixtures/creusot-live/Cargo.toml"
reject 'manifest/lock or release mismatch'
stage
sed -i '/#\[ensures/i #[trusted]' "$tmp/tree/tests/fixtures/creusot-live/src/lib.rs"
reject 'trusted fixture instead of an actual obligation'
stage
sed -i 's/^#\[ensures/\/\/ #[ensures/' "$tmp/tree/tests/fixtures/creusot-live/src/lib.rs"
reject 'line-commented postcondition'
stage
sed -i '/^#\[ensures/i /*' "$tmp/tree/tests/fixtures/creusot-live/src/lib.rs"
sed -i '/^#\[ensures/a */' "$tmp/tree/tests/fixtures/creusot-live/src/lib.rs"
reject 'block-commented postcondition'
stage
printf '#[trusted]\npub fn hidden_axiom() -> u32 { 0 }\n' > "$tmp/tree/tests/fixtures/creusot-live/src/extra.rs"
printf '\nmod extra;\n' >> "$tmp/tree/tests/fixtures/creusot-live/src/lib.rs"
reject 'additional module containing a trusted axiom'
echo 'ok: eight live-canary prerequisite mutants; no proof claimed'
