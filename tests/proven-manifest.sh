#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Conformance test for proven/manifest.json, the published list of stamped
# artifacts. The applier's read-only BEHIND-CONTENT census token reads this file
# at a pinned SHA of this repository: a stamped copy is BEHIND when its stamp
# names an older version than the manifest does.
#
# The manifest is only worth reading if it agrees with the bodies it describes:
#   * each entry's template starts with exactly the stamp the manifest records,
#     and the template body matches that stamp (scripts/proven-stamp.sh check);
#   * every stamped file under templates/ or .github/workflows/ is listed, and
#     a stamped copy installed here is the manifest's version, not BEHIND;
#   * artifact names are unique; versions are MAJOR.MINOR.PATCH.
# Then a set of mutants, each run on an isolated copy, must be refused.
# Exit: 0 conforms, 1 broken, 2 not run (no jq, or no manifest).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "proven-manifest: jq missing; NOT RUN" >&2; exit 2; }

# check DIR: conformance of DIR's manifest against DIR's files. Prints one FAIL
# line per broken rule; returns 0, 1, or 2 when there is nothing to judge.
check() {
  local dir=$1 m=$1/proven/manifest.json fail=0 rows
  [[ -f $m ]] || { echo "NOT RUN: $m missing"; return 2; }
  jq -e '.schema == "proven-cicd/manifest/v1" and (.artifacts | type == "array" and length > 0)' "$m" >/dev/null 2>&1 ||
    { echo "FAIL manifest is not proven-cicd/manifest/v1 with a non-empty artifacts list"; return 1; }
  if ! rows=$(jq -r '.artifacts[] | [.artifact, .version, .sha256, .template, .install_path] |
                     if all(type == "string") then @tsv else error("non-string field") end' "$m" 2>/dev/null); then
    echo "FAIL an artifact entry has a missing or non-string field"; return 1
  fi
  local dups
  dups=$(cut -f1 <<<"$rows" | sort | uniq -d)
  [[ -z $dups ]] || { echo "FAIL duplicate artifact: $dups"; fail=1; }
  local artifact version sha template install
  while IFS=$'\t' read -r artifact version sha template install; do
    [[ $artifact =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "FAIL artifact name $artifact"; fail=1; }
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "FAIL $artifact version $version is not MAJOR.MINOR.PATCH"; fail=1; }
    [[ $sha =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL $artifact sha256 $sha"; fail=1; }
    [[ $template =~ ^templates/[A-Za-z0-9._-]+\.ya?ml$ && -f $dir/$template ]] ||
      { echo "FAIL $artifact template $template missing or outside templates/"; fail=1; continue; }
    [[ $install =~ ^\.github/workflows/[A-Za-z0-9._-]+\.ya?ml$ ]] || { echo "FAIL $artifact install_path $install"; fail=1; }
    local want="# proven-cicd: $artifact@$version sha256:$sha"
    [[ $(head -n 1 "$dir/$template") == "$want" ]] ||
      { echo "FAIL $template stamp line is not the manifest's: $want"; fail=1; }
    bash "$dir/scripts/proven-stamp.sh" check "$dir/$template" >/dev/null 2>&1 ||
      { echo "FAIL $template body does not match its stamp"; fail=1; }
  done <<<"$rows"
  # Every stamped file here is listed; an installed copy is current.
  local f first name ver
  while IFS= read -r f; do
    first=$(head -n 1 "$f")
    name=${first#'# proven-cicd: '}; name=${name%%@*}
    ver=${first#*@}; ver=${ver%% *}
    grep -qxF "$name" <(cut -f1 <<<"$rows") || { echo "FAIL ${f#"$dir/"} names $name, which the manifest does not list"; fail=1; continue; }
    if [[ ${f#"$dir/"} == .github/workflows/* ]]; then
      [[ $ver == "$(awk -F'\t' -v a="$name" '$1 == a { print $2 }' <<<"$rows")" ]] ||
        { echo "FAIL ${f#"$dir/"} is $name@$ver, BEHIND or ahead of the manifest"; fail=1; }
      bash "$dir/scripts/proven-stamp.sh" check "$f" >/dev/null 2>&1 || { echo "FAIL ${f#"$dir/"} drifted from its stamp"; fail=1; }
    fi
  done < <(grep -rlE '^# proven-cicd: ' "$dir/templates" "$dir/.github/workflows" 2>/dev/null |
           while IFS= read -r p; do head -n 1 "$p" | grep -q '^# proven-cicd: ' && printf '%s\n' "$p"; done)
  return "$fail"
}

set +e
out=$(check "$root"); rc=$?
set -e
[[ -z $out ]] || printf '%s\n' "$out"
case $rc in
  0) echo "ok: proven/manifest.json agrees with every stamped body" ;;
  2) echo "proven-manifest: NOT RUN" >&2; exit 2 ;;
  *) echo "proven-manifest: FAIL" >&2; exit 1 ;;
esac

# Mutants. Each runs on a fresh copy and must be refused with exit 1 (or 2 for
# a missing manifest), never accepted.
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fresh() {
  rm -rf -- "$tmp/r"; mkdir -p "$tmp/r/scripts" "$tmp/r/.github"
  cp -R "$root/proven" "$root/templates" "$tmp/r/"
  cp -R "$root/.github/workflows" "$tmp/r/.github/"
  cp "$root/scripts/proven-stamp.sh" "$tmp/r/scripts/"
}
refuse() {
  local name=$1 want=$2 got
  set +e; check "$tmp/r" >"$tmp/out" 2>&1; got=$?; set -e
  if [[ $got != "$want" ]]; then
    echo "FAIL: mutant '$name' gave exit $got, want $want" >&2; cat "$tmp/out" >&2; exit 1
  fi
  echo "ok: refused $name: $(head -n 1 "$tmp/out")"
}
edit_json() {
  local filter=$1
  jq "$filter" "$tmp/r/proven/manifest.json" > "$tmp/m" && mv "$tmp/m" "$tmp/r/proven/manifest.json"
}

fresh; printf '# hand edit\n' >> "$tmp/r/templates/proven-lock-gate.yml"
refuse 'template body edited without restamping' 1
fresh; printf '# hand edit\n' >> "$tmp/r/templates/proven-lock-gate.yml"
bash "$tmp/r/scripts/proven-stamp.sh" stamp "$tmp/r/templates/proven-lock-gate.yml" >/dev/null
refuse 'template restamped but manifest hash not updated' 1
fresh; edit_json '.artifacts[0].version = "0.2.0"'
refuse 'manifest version ahead of the template stamp' 1
fresh; edit_json '.artifacts[0].sha256 = ("0" * 64)'
refuse 'manifest hash for another body' 1
fresh; edit_json '.artifacts += [.artifacts[0]]'
refuse 'duplicate artifact' 1
fresh; edit_json '.artifacts[0].version = "0.1"'
refuse 'version not MAJOR.MINOR.PATCH' 1
fresh; edit_json 'del(.artifacts[0].install_path)'
refuse 'missing field' 1
fresh; edit_json '.artifacts = []'
refuse 'empty artifacts list' 1
fresh; sed '1s/proven-lock-gate@/unlisted-gate@/' "$tmp/r/templates/proven-lock-gate.yml" > "$tmp/r/templates/unlisted.yml"
refuse 'stamped template the manifest does not list' 1
fresh; sed -i '1s/@0\.1\.0 /@0.0.9 /' "$tmp/r/.github/workflows/proven-lock-gate.yml"
refuse 'installed copy BEHIND the manifest' 1
fresh; rm "$tmp/r/proven/manifest.json"
refuse 'manifest missing' 2
echo "proven-manifest: manifest conforms; 11 mutants refused"
