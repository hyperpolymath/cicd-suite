#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Run the actual bootstrap shells from every reusable; do not reimplement them.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
command -v yq >/dev/null || { echo 'mikefarah yq v4 is required' >&2; exit 2; }
command -v jq >/dev/null || { echo 'jq is required' >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/subject/.github/workflows" "$tmp/.github/workflows"
sha=0123456789abcdef0123456789abcdef01234567
other_sha=ffffffffffffffffffffffffffffffffffffffff
legacy=hyperpolymath/cicd-suite
canonical=hyperpolymath/proven-cicd
caller=hyperpolymath/source-control
caller_file=.github/workflows/caller.yml

stage_ref() {
    printf 'name: Subject\njobs:\n  scan:\n    uses: %s\n' "$1" > "$tmp/$caller_file"
    cp "$tmp/$caller_file" "$tmp/subject/$caller_file"
}
stage_text() {
    printf '%s\n' "$1" > "$tmp/$caller_file"
    cp "$tmp/$caller_file" "$tmp/subject/$caller_file"
}
run_case() {
    local want=$1 label=$2 expected_repository=${3:-} rc=0
    : > "$tmp/outputs"
    (
        cd "$tmp"
        GITHUB_REPOSITORY=$caller GITHUB_WORKFLOW_REF="$caller/$caller_file@refs/pull/42/merge" \
        CALLER_REPO=$caller CALLER_REF="$caller/$caller_file@refs/pull/42/merge" \
        GITHUB_OUTPUT="$tmp/outputs" SUITE_WORKFLOW=$workflow bash "$tmp/resolve.sh"
    ) > "$tmp/log" 2>&1 || rc=$?
    [[ "$rc" == "$want" ]] || { cat "$tmp/log"; echo "FAIL $workflow/$job $label: wanted $want, got $rc"; exit 1; }
    if [[ "$want" == 0 ]]; then
        grep -Fxq "repository=$expected_repository" "$tmp/outputs"
        grep -Fxq "sha=$sha" "$tmp/outputs"
        [[ $(wc -l < "$tmp/outputs") -eq 2 ]]
    else
        [[ ! -s "$tmp/outputs" ]] || { echo 'Rejected source emitted checkout outputs'; exit 1; }
    fi
}

resolved=0
for workflow in rust-ci.yml creusot-gate.yml spark-gate.yml kanren-gate.yml secret-scanner-reusable.yml; do
    yq -o=json '.' "$root/.github/workflows/$workflow" > "$tmp/workflow.json"
    mapfile -t jobs < <(jq -r '.jobs | to_entries[] | select(any(.value.steps[]?; .id == "suite")) | .key' "$tmp/workflow.json")
    [[ "${#jobs[@]}" -gt 0 ]] || { echo "$workflow has no checked resolver"; exit 1; }
    for job in "${jobs[@]}"; do
        jq -r --arg job "$job" '.jobs[$job].steps[] | select(.id == "suite") | .run' "$tmp/workflow.json" > "$tmp/resolve.sh"
        bash -n "$tmp/resolve.sh"
        # The chosen coordinate and SHA must reach the implementation checkout.
        jq -e --arg job "$job" '
          [.jobs[$job].steps[] | select(.with.path == ".cicd-suite" or .with.path == "suite")] |
          length == 1 and all(.[];
            .with.repository == "${{ steps.suite.outputs.repository }}" and
            .with.ref == "${{ steps.suite.outputs.sha }}" and
            .with["persist-credentials"] == false)
        ' "$tmp/workflow.json" >/dev/null

        for repository in "$legacy" "$canonical"; do
            ref="$repository/.github/workflows/$workflow@$sha"
            stage_ref "$ref"
            run_case 0 'admitted coordinate' "$repository"
            stage_ref "'$ref'"
            run_case 0 'quoted YAML reference' "$repository"
            for invalid in main "$sha-extra" "${sha}0" "$sha@$sha"; do
                stage_ref "$repository/.github/workflows/$workflow@$invalid"
                run_case 2 'nonexact SHA refused'
            done
        done

        stage_ref "untrusted/proven-cicd/.github/workflows/$workflow@$sha"
        run_case 2 'unadmitted owner refused'
        stage_ref "$canonical/.github/workflows/unrelated.yml@$sha"
        run_case 2 'wrong workflow refused'
        stage_text "# uses: $canonical/.github/workflows/$workflow@$sha
jobs:
  scan:
    runs-on: ubuntu-24.04
    steps:
      - run: echo no-reusable"
        run_case 2 'comment is not a workflow call'
        stage_text 'jobs: [unclosed'
        run_case 2 'invalid YAML refused'
        rm "$tmp/$caller_file" "$tmp/subject/$caller_file"
        run_case 2 'absent caller refused'

        if [[ "$workflow" != secret-scanner-reusable.yml ]]; then
            stage_text "jobs:
  first:
    uses: $legacy/.github/workflows/$workflow@$sha
  second:
    uses: $canonical/.github/workflows/$workflow@$sha"
            run_case 2 'same SHA under ambiguous coordinates refused'
            stage_text "jobs:
  first:
    uses: $legacy/.github/workflows/$workflow@$sha
  second:
    uses: $legacy/.github/workflows/$workflow@$other_sha"
            run_case 2 'multiple SHAs refused'
            stage_text "jobs:
  first:
    uses: $legacy/.github/workflows/$workflow@$sha
  second:
    uses: $legacy/.github/workflows/$workflow@main"
            run_case 2 'floating second call cannot hide beside a valid pin'
            stage_text "jobs:
  first:
    uses: $canonical/.github/workflows/$workflow@$sha
  second:
    uses: $canonical/.github/workflows/$workflow@$sha"
            run_case 0 'identical direct calls share one source' "$canonical"
        fi
        resolved=$((resolved + 1))
        echo "ok: $workflow/$job accepts both names and refuses untrusted source selections"
    done
done
[[ "$resolved" -eq 12 ]] || { echo "Expected all 12 bootstrap sites, got $resolved"; exit 1; }

# SHA checking remains mandatory after the selected repository is checked out.
checkout="$tmp/checkout"
git init -q "$checkout"
for gate in rust-ci-check creusot-check spark-check kanren-check; do
    mkdir -p "$checkout/actions/$gate"
    printf '#!/usr/bin/env bash\n' > "$checkout/actions/$gate/check.sh"
done
git -C "$checkout" add actions
git -C "$checkout" -c user.name='CI control' -c user.email='ci-control@example.invalid' commit -qm 'source checkout fixture'
actual=$(git -C "$checkout" rev-parse HEAD)
for repository in "$legacy" "$canonical"; do
    EXPECTED=$actual EXPECTED_REPOSITORY=$repository SUITE_DIR=$checkout \
        bash "$root/scripts/verify-suite-checkout.sh" >/dev/null
done
for repository in untrusted/proven-cicd ''; do
    rc=0
    EXPECTED=$actual EXPECTED_REPOSITORY=$repository SUITE_DIR=$checkout \
        bash "$root/scripts/verify-suite-checkout.sh" > "$tmp/log" 2>&1 || rc=$?
    [[ "$rc" -eq 2 ]] || { echo 'Unadmitted checkout source was accepted'; exit 1; }
done
rc=0
EXPECTED=$other_sha EXPECTED_REPOSITORY=$canonical SUITE_DIR=$checkout \
    bash "$root/scripts/verify-suite-checkout.sh" > "$tmp/log" 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || { echo 'Mismatched checkout SHA was accepted'; exit 1; }
echo 'ok: checkout source admission and exact SHA verification remain enforcing'

# Exercise the real corpus-plan block as well: only an absent field retains
# the legacy default. Explicit null/false/empty values must not silently select it.
plan="$tmp/canary-plan"
mkdir -p "$plan/scripts" "$plan/config/gitleaks" "$plan/mocks"
cp "$root/scripts/verify-published-scanner-pin.sh" "$plan/scripts/"
yq -r '.jobs.plan.steps[] | select(.id == "plan") | .run' \
  "$root/.github/workflows/secret-scanner-consumer-canaries.yml" > "$plan/plan.sh"
[[ -s "$plan/plan.sh" ]] || exit 2
cat > "$plan/mocks/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$PLAN_PROBE_LOG"
[[ "$1" == api && "$2" == "repos/$PLAN_EXPECTED_REPOSITORY/compare/$PLAN_EXPECTED_SHA...main" && "$3" == --jq && "$4" == .status ]] || exit 99
echo identical
MOCK
chmod +x "$plan/mocks/gh"
for selected in "$legacy" "$canonical" __omitted__ __null__ __false__ '' untrusted/proven-cicd hyperpolymath/proven-cicd-extra; do
    jq -n --arg repository "$selected" --arg sha "$sha" '
      {schema_version:1,suite_sha:$sha,subjects:[{repository:"hyperpolymath/source-control",sha:$sha}]} |
      if $repository == "__omitted__" then .
      elif $repository == "__null__" then .suite_repository = null
      elif $repository == "__false__" then .suite_repository = false
      else .suite_repository = $repository end
    ' > "$plan/config/gitleaks/consumer-canaries.json"
    expected_repository=$selected
    [[ "$selected" != __omitted__ ]] || expected_repository=$legacy
    : > "$plan/probes"
    : > "$plan/outputs"
    rc=0
    (cd "$plan" && PATH="$plan/mocks:$PATH" PLAN_PROBE_LOG="$plan/probes" \
      PLAN_EXPECTED_REPOSITORY=$expected_repository PLAN_EXPECTED_SHA=$sha \
      GITHUB_OUTPUT="$plan/outputs" bash plan.sh) > "$tmp/log" 2>&1 || rc=$?
    case "$selected" in
      "$legacy"|"$canonical"|__omitted__)
        [[ "$rc" -eq 0 && -s "$plan/probes" ]]
        grep -Fxq "suite_repository=$expected_repository" "$plan/outputs"
        grep -Fxq "suite_sha=$sha" "$plan/outputs"
        ;;
      *) [[ "$rc" -eq 1 && ! -s "$plan/probes" && ! -s "$plan/outputs" ]] ;;
    esac
done
echo 'ok: corpus planning admits both exact sources and defaults only an absent repository field'
