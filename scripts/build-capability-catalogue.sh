#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Validate reviewed catalogue metadata and render visitor-facing AsciiDoc.
# --check is read-only. CATALOGUE_ROOT supports isolated regression fixtures.
set -euo pipefail
ROOT=${CATALOGUE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
ROOT=$(realpath -e "$ROOT")
mode=${1:-}
[[ $# -le 1 && ( -z $mode || $mode == --check ) ]] || { echo 'usage: build-capability-catalogue.sh [--check]' >&2; exit 2; }
for tool in jq realpath cmp; do command -v "$tool" >/dev/null || { echo "$tool required" >&2; exit 2; }; done
inventory=$ROOT/catalogue/capabilities.json
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
jq -e -f "$ROOT/catalogue/validate.jq" "$inventory" >/dev/null || { echo 'invalid catalogue metadata' >&2; exit 1; }
while IFS= read -r target; do
    resolved=$(realpath -e "$ROOT/$target") || { echo "missing catalogue target: $target" >&2; exit 1; }
    [[ $resolved == "$ROOT/"* && -f $resolved ]] || { echo "escaping catalogue target: $target" >&2; exit 1; }
done < <(jq -r '.capabilities[] | (.path, .workflow, .template) | select(. != null)' "$inventory")
for path in "$ROOT"/actions/*/action.yml; do
    [[ ! -f $path ]] || printf '%s\n' "${path#"$ROOT/"}"
done | LC_ALL=C sort > "$tmp/actual"
jq -r '.capabilities[].path' "$inventory" | LC_ALL=C sort > "$tmp/declared"
cmp -s "$tmp/actual" "$tmp/declared" || { echo 'action inventory drift: every action must appear exactly once' >&2; exit 1; }
jq -c -f "$ROOT/catalogue/render.jq" "$inventory" > "$tmp/pages.jsonl"
mkdir -p "$tmp/pages"
while IFS= read -r record; do
    page=$(jq -er '.path' <<< "$record")
    [[ $page == CATALOGUE.adoc || $page =~ ^catalogue/clades/[a-z][a-z0-9-]*\.adoc$ ]] || exit 1
    mkdir -p "$tmp/pages/$(dirname "$page")"
    jq -j '.content' <<< "$record" > "$tmp/pages/$page"
    if [[ $mode == --check ]]; then
        cmp -s "$tmp/pages/$page" "$ROOT/$page" || { echo "stale catalogue page: $page" >&2; exit 1; }
    fi
done < "$tmp/pages.jsonl"
# Reject orphan generated pages; never silently delete a page from the repo.
for page in "$ROOT"/catalogue/clades/*.adoc; do
    [[ ! -f $page || -f "$tmp/pages/catalogue/clades/$(basename "$page")" ]] || { echo "orphan clade page: $page" >&2; exit 1; }
done
if [[ $mode != --check ]]; then
    mkdir -p "$ROOT/catalogue/clades"
    cp "$tmp/pages/CATALOGUE.adoc" "$ROOT/CATALOGUE.adoc"
    cp "$tmp/pages/catalogue/clades/"*.adoc "$ROOT/catalogue/clades/"
fi
jq -r '"Catalogue: \(.capabilities|length) actions, \(.clades|length) clades; inventory and pages valid"' "$inventory"
