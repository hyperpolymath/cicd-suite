#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# extract-lock-facts.sh ROOT [--oracle FILE]
#
# Emits the facts the proven lock kernel judges (schema
# proven-cicd/lock-facts/v1) on stdout. It decides nothing: every verdict comes
# from the total Idris2 function in src/Proven/Lock/Judge.idr. It extracts:
#   * every workflow under ROOT/.github/workflows: its step-level remote keys,
#     its same-repository composite references and its job-level reusable
#     calls;
#   * every same-repository composite reached from those, transitively, with
#     the same three lists (a composite whose action.yml/.yaml is missing is
#     simply absent, and the kernel then refuses with NOT RUN);
#   * the actions.lock entries and dependency records, field by field;
#   * the `uses:` forms that cannot run (`../`, `$/`, expressions,
#     unparseable refs), listed as illegal with where they occur.
#
# Normalisation (shared by workflow refs and lock keys, so they compare):
#   owner and repo are lowercased, a 40-hex ref is lowercased, other refs are
#   kept verbatim, and a sub-path (`actions/cache/restore@x`) keys as its
#   repository (`actions/cache@x`). `docker://` steps are not lock subjects.
#   A job-level `./` call is a local reusable workflow: it is judged as its
#   own workflow file, not as part of its caller's entry.
#   A step-level `$/x` is a same-repository composite, like `./x`. Measured:
#   this repository's code-hygiene-self-test.yml uses `$/actions/...` and
#   ran green on main (run 42860149575, 2026-11-10). A job-level `$/` and
#   any `../` are illegal.#
# Exit: 0 facts written; 2 NOT RUN (missing tool, unreadable or unparsable
# input). A gate that cannot read its subject must never look clean.
set -euo pipefail

die() { printf 'extract-lock-facts: %s; NOT RUN\n' "$1" >&2; exit 2; }

root=${1:-}
[[ -n $root && -d $root ]] || die "usage: extract-lock-facts.sh ROOT [--oracle FILE]"
shift
oracle=null
while [[ $# -gt 0 ]]; do
  case $1 in
    --oracle) [[ -f ${2:-} ]] || die "oracle file missing"
              oracle=$(jq -c . "$2") || die "oracle is not JSON"; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done

command -v jq >/dev/null || die "jq is required"
yq --version 2>/dev/null | grep -q mikefarah || die "mikefarah yq v4 is required"

wfdir="$root/.github/workflows"
lock="$wfdir/actions.lock"
[[ -d $wfdir ]] || die "no .github/workflows directory"
[[ -f $lock ]] || die "no actions.lock"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# Shared jq library: classify one raw `uses:` string at a level (step|job).
cat > "$tmp/norm.jq" <<'JQ'
def sha40: test("^[0-9a-fA-F]{40}$");
def normkey:
  capture("^(?<o>[^/@]+)/(?<r>[^/@]+)(?<sub>/[^@]*)?@(?<ref>[^@]+)$")
  | (.o | ascii_downcase) + "/" + (.r | ascii_downcase) + "@"
    + (if (.ref | sha40) then (.ref | ascii_downcase) else .ref end);
def classify($level):
  (gsub("^\\s+|\\s+$"; "")) as $u
  | if ($u | test("\\$\\{\\{")) then {illegal: $u}
    elif ($u | startswith("docker://")) then {ignore: $u}
    elif ($u | startswith("../")) then {illegal: $u}
    elif ($u | startswith("./")) then
      (if $level == "job" then {ignore: $u}
       else {local: ($u | ltrimstr("./") | sub("/+$"; ""))} end)
    elif ($u | startswith("$/")) then
      (if $level == "job" then {illegal: $u}
       else {local: ($u | ltrimstr("$/") | sub("/+$"; ""))} end)
    elif ($u | test("^[^/@]+/[^@]+@[^@]+$")) then
      (if $level == "job" then {call: ($u | normkey)} else {remote: ($u | normkey)} end)
    else {illegal: $u} end;
JQ

# uses_of FILE KIND: one JSON object per `uses:` with its level.
uses_of() {
  local file=$1 kind=$2 json
  json=$(yq -o json -I 0 '.' "$file" 2>/dev/null) || die "$file does not parse"
  if [[ $kind == workflow ]]; then
    jq -c -L "$tmp" 'include "norm";
      [ ((.jobs // {}) | to_entries[] | .value | objects |
          ((.uses // empty | select(type == "string") | classify("job")),
           ((.steps // []) | .[] | objects | .uses // empty | select(type == "string") | classify("step")))) ]' <<<"$json"
  else
    jq -c -L "$tmp" 'include "norm";
      [ (.runs.steps // []) | .[] | objects | .uses // empty | select(type == "string") | classify("step") ]' <<<"$json"
  fi
}

node_of() { # CLASSIFIED_JSON LOCATION -> {direct, locals, job_calls, illegal}
  jq -c --arg at "$2" '{
    direct: ([.[] | .remote // empty] | unique),
    locals: ([.[] | .local // empty] | unique),
    job_calls: ([.[] | .call // empty] | unique),
    illegal: [.[] | .illegal // empty | {at: $at, uses: .}] }' <<<"$1"
}

: > "$tmp/workflows.jsonl"
: > "$tmp/illegal.jsonl"
queue=()
shopt -s nullglob
for wf in "$wfdir"/*.yml "$wfdir"/*.yaml; do
  rel=".github/workflows/$(basename "$wf")"
  n=$(node_of "$(uses_of "$wf" workflow)" "$rel")
  jq -c --arg p "$rel" '{path: $p, direct, locals, job_calls}' <<<"$n" >> "$tmp/workflows.jsonl"
  jq -c '.illegal[]' <<<"$n" >> "$tmp/illegal.jsonl"
  while IFS= read -r l; do queue+=("$l"); done < <(jq -r '.locals[]' <<<"$n")
done

: > "$tmp/composites.jsonl"
declare -A seen=()
while [[ ${#queue[@]} -gt 0 ]]; do
  id=${queue[0]}; queue=("${queue[@]:1}")
  [[ -n ${seen[$id]:-} ]] && continue
  seen[$id]=1
  # Containment: a composite id must resolve inside ROOT.
  case "/$id/" in */../*) printf '%s\n' "$(jq -cn --arg u "./$id" '{at: "composite", uses: $u}')" >> "$tmp/illegal.jsonl"; continue ;; esac
  meta=
  for name in action.yml action.yaml; do
    [[ -f $root/$id/$name ]] && { meta=$root/$id/$name; break; }
  done
  [[ -n $meta ]] || continue   # absent: the kernel refuses (NOT RUN)
  n=$(node_of "$(uses_of "$meta" composite)" "$id")
  jq -c --arg id "$id" '{id: $id, direct, locals}' <<<"$n" >> "$tmp/composites.jsonl"
  jq -c '.illegal[]' <<<"$n" >> "$tmp/illegal.jsonl"
  while IFS= read -r l; do queue+=("$l"); done < <(jq -r '.locals[]' <<<"$n")
done

lockjson=$(yq -o json -I 0 '.' "$lock" 2>/dev/null) || die "actions.lock does not parse"
jq -e '(.workflows | type == "object") and (.dependencies | type == "object")' \
  <<<"$lockjson" >/dev/null || die "actions.lock lacks workflows/dependencies mappings"
jq -e '[.workflows[] | type == "array" and all(.[]; type == "string")] | all' \
  <<<"$lockjson" >/dev/null || die "an actions.lock workflow entry is not a list of strings"

jq -c -L "$tmp" --argjson oracle "$oracle" \
  --slurpfile wfs "$tmp/workflows.jsonl" --slurpfile comps "$tmp/composites.jsonl" \
  --slurpfile ill "$tmp/illegal.jsonl" 'include "norm";
  def k: if test("^[^/@]+/[^/@]+@[^@]+$") then normkey else . end;
  def num: if type == "number" then . else null end;
  def str: if type == "string" then . else null end;
  { schema: "proven-cicd/lock-facts/v1",
    composites: $comps, workflows: $wfs, illegal: $ill,
    entries: [.workflows | to_entries[] | {path: .key, keys: [.value[] | k]}],
    records: [.dependencies | to_entries[] | {
      key: (.key | k),
      ref: (.value.ref | str), commit: (.value.commit | str),
      owner_id: (.value.owner_id | num), repo_id: (.value.repo_id | num),
      uses: (.value.uses as $u
             | if $u == null then null
               elif ($u | type) == "array" and all($u[]; type == "string") then [$u[] | k]
               else "MALFORMED" end) }],
    oracle: $oracle }' <<<"$lockjson"
