#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# 0 = both scans passed; 1 = findings; 2 = no trustworthy verdict.
# Inputs are environment variables, never interpolated shell fragments.
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
subject=$(realpath "${SUBJECT:-.}")
scanner=$(realpath "${GITLEAKS_BIN:?GITLEAKS_BIN is required}")
baseline=$(realpath "${ESTATE_BASELINE:?ESTATE_BASELINE is required}")
mode=${SCAN_MODE:-full}
seconds=${SCAN_TIMEOUT_SECONDS:-180}
[[ $mode == full || $mode == pr-range ]] || { echo 'invalid scan mode' >&2; exit 2; }
[[ $seconds =~ ^[1-9][0-9]*$ && $seconds -le 600 ]] || { echo 'invalid scan deadline (1..600 seconds)' >&2; exit 2; }
[[ -x $scanner && -s $baseline ]] || { echo 'missing scanner or baseline' >&2; exit 2; }
cd "$subject"
[[ $(git rev-parse --show-toplevel) == "$subject" ]] || { echo 'subject must be repository root' >&2; exit 2; }
[[ $(git rev-parse --is-shallow-repository) == false ]] || { echo 'incomplete ancestry: refusing shallow history' >&2; exit 2; }
head=$(git rev-parse HEAD)
log_opts='--all'
population=$(git rev-list --all --count)
if [[ $mode == pr-range ]]; then
    base=${BASE_SHA:-} expected_head=${HEAD_SHA:-}
    [[ $base =~ ^[0-9a-f]{40}$ && $expected_head =~ ^[0-9a-f]{40}$ && $head == "$expected_head" ]] \
        || { echo 'invalid base/head or checkout does not match PR head' >&2; exit 2; }
    git cat-file -e "$base^{commit}" || exit 2
    git merge-base --is-ancestor "$base" "$head" || { echo 'base is not an ancestor; full scan required' >&2; exit 2; }
    # Every introduced commit, not only the final diff. A secret added and
    # deleted within the PR remains in this population.
    log_opts="$base..$head"
    population=$(git rev-list --count "$log_opts")
fi
# Shared config matches the pinned suite revision. Keep consumer-specific
# exceptions, but do not silently overwrite an existing baseline or symlink.
staged=0
if [[ -e .gitleaks-estate.toml || -L .gitleaks-estate.toml ]]; then
    [[ ! -L .gitleaks-estate.toml ]] && cmp -s "$baseline" .gitleaks-estate.toml \
        || { echo 'existing estate baseline differs; explicit migration required' >&2; exit 2; }
else
    cp "$baseline" .gitleaks-estate.toml
    staged=1
fi
# Remove the estate baseline on exit only when this scan staged it.
cleanup() { if [[ $staged == 1 ]]; then rm -f .gitleaks-estate.toml; fi; }
trap cleanup EXIT
config=.gitleaks-estate.toml
[[ ! -f .gitleaks.toml ]] || config=.gitleaks.toml
GITLEAKS_BIN="$scanner" bash "$script_dir/control.sh" "$config" || exit 2
version=$("$scanner" version) || exit 2
printf 'scanner=%s mode=%s head=%s history_commits=%s\n' "$version" "$mode" "$head" "$population"
verdict=0
for pass in tree history; do
    started=$SECONDS
    args=(--config "$config" --redact=100 --no-banner --exit-code 10 --verbose)
    if [[ $pass == tree ]]; then
        command=("$scanner" dir . "${args[@]}")
    else
        command=("$scanner" git . --log-opts "$log_opts" "${args[@]}")
    fi
    rc=0
    timeout --signal=TERM --kill-after=10s "${seconds}s" "${command[@]}" || rc=$?
    printf 'pass=%s elapsed_seconds=%s exit=%s\n' "$pass" "$((SECONDS-started))" "$rc"
    case $rc in
        0) ;;
        10) [[ $verdict == 2 ]] || verdict=1 ;;
        *) verdict=2 ;;
    esac
done
printf 'verdict=%s (0=passed, 1=findings, 2=infrastructure/configuration/timeout)\n' "$verdict"
exit "$verdict"
