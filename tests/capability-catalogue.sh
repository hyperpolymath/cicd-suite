#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Inventory/navigation regression tests with actual jq and isolated mutants.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
builder=$ROOT/scripts/build-capability-catalogue.sh
bash "$builder" --check
n=$(jq '.capabilities | length' "$ROOT/catalogue/capabilities.json")
c=$(jq '.clades | length' "$ROOT/catalogue/capabilities.json")
grep -Fq "*$n composite actions" "$ROOT/README.adoc"
grep -Fq "in $c clades*" "$ROOT/README.adoc"
echo 'ok: README entrypoint and counts'
grep -Fq 'link:CATALOGUE.adoc[' "$ROOT/README.adoc"
while IFS= read -r page; do
    while IFS= read -r target; do
        [[ -f "$(dirname "$page")/$target" ]] || { echo "broken link: $page -> $target" >&2; exit 1; }
    done < <(grep -oE 'link:[^[]+\[' "$page" | sed 's/^link://; s/\[$//')
done < <(printf '%s\n' "$ROOT/CATALOGUE.adoc" "$ROOT"/catalogue/clades/*.adoc)
while IFS= read -r target; do
    grep -Fxq "[[$target]]" "$ROOT/CATALOGUE.adoc" || { echo "missing clade anchor: $target" >&2; exit 1; }
done < <(grep -oE '<<[^,>]+,' "$ROOT/CATALOGUE.adoc" | sed 's/^<<//; s/,$//')
echo 'ok: all generated navigation targets and anchors resolve'
fixture=$tmp/tree
mkdir "$fixture"
cp -a "$ROOT/actions" "$ROOT/catalogue" "$ROOT/templates" "$ROOT/.github" "$ROOT/docs" "$ROOT/README.adoc" "$ROOT/CATALOGUE.adoc" "$fixture/"
CATALOGUE_ROOT=$fixture bash "$builder" --check >/dev/null
expect_failure() {
    local name=$1
    if CATALOGUE_ROOT=$fixture bash "$builder" --check > "$tmp/log" 2>&1; then
        echo "FAIL: accepted mutant $name" >&2; exit 1
    fi
    echo "ok: refused $name"
}
mutate() {
    jq "$2" "$ROOT/catalogue/capabilities.json" > "$fixture/catalogue/capabilities.json"
    expect_failure "$1"
    cp "$ROOT/catalogue/capabilities.json" "$fixture/catalogue/capabilities.json"
}
mutate 'dropped action' '.capabilities |= .[:-1]'
mutate 'duplicate action' '.capabilities += [.capabilities[0]]'
mutate 'unknown clade' '.capabilities[0].clade="imaginary"'
mutate 'unknown status' '.capabilities[0].status="certified-perfect"'
mutate 'unknown nature' '.capabilities[0].nature="magic"'
mutate 'path traversal' '.capabilities[0].workflow="../outside.yml"'
mutate 'missing target' '.capabilities[0].workflow=".github/workflows/absent.yml"'
mutate 'placeholder relabelled enforcing' '(.capabilities[] | select(.status=="stub")).status="enforcing"'
mutate 'empty assurance boundary' '.capabilities[0].limitations=" "'
mutate 'unsupported schema' '.schema_version=99'
mutate 'empty clade' '.clades += [{id:"empty",title:"Empty",summary:"No entries"}]'
mkdir "$fixture/actions/uncatalogued-check"
printf 'name: uncatalogued\n' > "$fixture/actions/uncatalogued-check/action.yml"
expect_failure 'uncatalogued new action'
rm "$fixture/actions/uncatalogued-check/action.yml"
rmdir "$fixture/actions/uncatalogued-check"
first=$(jq -r '.capabilities[0].path' "$ROOT/catalogue/capabilities.json")
cp "$fixture/$first" "$tmp/action.yml"
rm "$fixture/$first"
ln -s "$tmp/action.yml" "$fixture/$first"
expect_failure 'symlink escape'
rm "$fixture/$first"
cp "$tmp/action.yml" "$fixture/$first"
printf 'stale\n' > "$fixture/CATALOGUE.adoc"
expect_failure 'stale output'
cp "$ROOT/CATALOGUE.adoc" "$fixture/CATALOGUE.adoc"
printf 'orphan\n' > "$fixture/catalogue/clades/orphan.adoc"
expect_failure 'orphan page'
rm "$fixture/catalogue/clades/orphan.adoc"
# A real regeneration must be deterministic and recreate the original pages.
CATALOGUE_ROOT=$fixture bash "$builder" >/dev/null
cmp "$ROOT/CATALOGUE.adoc" "$fixture/CATALOGUE.adoc"
diff -r "$ROOT/catalogue/clades" "$fixture/catalogue/clades"
CATALOGUE_ROOT=$fixture bash "$builder" --check >/dev/null
echo 'ok: deterministic regeneration, current pages and 15 negative controls'
