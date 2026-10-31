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
trusted_dir=
# Remove the estate baseline on exit only when this scan staged it.
cleanup() {
    if [[ ${staged:-0} == 1 ]]; then rm -f "$subject/.gitleaks-estate.toml"; fi
    if [[ -n $trusted_dir ]]; then rm -rf "$trusted_dir"; fi
}
trap cleanup EXIT
scan_dir=$subject
if [[ ${GITHUB_EVENT_NAME:-} == pull_request ]]; then
    pr_base=${PR_BASE:-} pr_head=${PR_HEAD:-}
    [[ $pr_base =~ ^[0-9a-f]{40}$ && $pr_head =~ ^[0-9a-f]{40}$ && $head == "$pr_head" ]] \
        || { echo 'invalid PR base/head or checkout does not match PR head' >&2; exit 2; }
    git cat-file -e "$pr_base^{commit}" || exit 2
    # Gitleaks also loads .gitleaksignore from the scan source automatically.
    # Refuse changed, untracked, or symlinked ignore files on PRs.
    if git cat-file -e "$pr_base:.gitleaksignore" 2>/dev/null; then
        [[ $(git ls-tree "$pr_base" -- .gitleaksignore) == '100644 blob '* || $(git ls-tree "$pr_base" -- .gitleaksignore) == '100755 blob '* ]] \
            && [[ -f .gitleaksignore && ! -L .gitleaksignore ]] \
            && git show "$pr_base:.gitleaksignore" | cmp -s - .gitleaksignore \
            || { echo 'PR ignore file differs from trusted base' >&2; exit 2; }
    elif [[ -e .gitleaksignore || -L .gitleaksignore ]]; then
        echo 'PR ignore file differs from trusted base' >&2; exit 2
    fi
    # Extended config paths are resolved from the current directory. Materialize
    # the base tree outside the subject so PR files cannot supply those paths.
    trusted_dir=$(mktemp -d)
    mkdir "$trusted_dir/tree"
    GIT_INDEX_FILE="$trusted_dir/index" git read-tree "$pr_base"
    GIT_INDEX_FILE="$trusted_dir/index" git --work-tree="$trusted_dir/tree" checkout-index --all
    scan_dir=$trusted_dir/tree
fi
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
config=.gitleaks-estate.toml
if [[ $scan_dir != "$subject" ]]; then
    if [[ -e $scan_dir/.gitleaks-estate.toml || -L $scan_dir/.gitleaks-estate.toml ]]; then
        [[ ! -L $scan_dir/.gitleaks-estate.toml ]] && cmp -s "$baseline" "$scan_dir/.gitleaks-estate.toml" \
            || { echo 'trusted estate baseline differs; explicit migration required' >&2; exit 2; }
    else
        cp "$baseline" "$scan_dir/.gitleaks-estate.toml"
    fi
fi
if [[ -f $scan_dir/.gitleaks.toml || ( $scan_dir != "$subject" && -L $scan_dir/.gitleaks.toml ) ]]; then
    config=.gitleaks.toml
fi
if [[ $scan_dir != "$subject" ]]; then
    # Gitleaks resolves extend.path from its working directory, including
    # absolute paths and symlinks. Only allow files inside the base tree.
    python3 - "$scan_dir" "$config" <<'PY' || exit 2
import pathlib
import sys
import tomllib

root = pathlib.Path(sys.argv[1]).resolve()
path = root / sys.argv[2]
try:
    for _ in range(3):  # Gitleaks follows at most two extensions.
        path = path.resolve(strict=True)
        if not path.is_relative_to(root) or not path.is_file():
            raise ValueError("config path escapes trusted base")
        with path.open("rb") as file:
            data = tomllib.load(file)
        fields = {key.lower(): value for key, value in data.items()}
        extend = fields.get("extend", {})
        extend = {key.lower(): value for key, value in extend.items()}
        next_path = extend.get("path", "")
        if not next_path:
            break
        path = root / next_path
except (OSError, ValueError, TypeError, AttributeError) as error:
    print(f"untrusted or invalid scanner configuration: {error}", file=sys.stderr)
    sys.exit(2)
PY
fi
(cd "$scan_dir" && GITLEAKS_BIN="$scanner" bash "$script_dir/control.sh" "$config") || exit 2
version=$("$scanner" version) || exit 2
printf 'scanner=%s mode=%s head=%s history_commits=%s\n' "$version" "$mode" "$head" "$population"
verdict=0
for pass in tree history; do
    started=$SECONDS
    args=(--config "$config" --redact=100 --no-banner --exit-code 10 --verbose)
    if [[ $pass == tree ]]; then
        command=("$scanner" dir "$subject" "${args[@]}")
    else
        command=("$scanner" git "$subject" --log-opts "$log_opts" "${args[@]}")
    fi
    rc=0
    (cd "$scan_dir" && timeout --signal=TERM --kill-after=10s "${seconds}s" "${command[@]}") || rc=$?
    printf 'pass=%s elapsed_seconds=%s exit=%s\n' "$pass" "$((SECONDS-started))" "$rc"
    case $rc in
        0) ;;
        10) [[ $verdict == 2 ]] || verdict=1 ;;
        *) verdict=2 ;;
    esac
done
# Preserve the old bundle's unique Rust/shell heuristics. PR shell ignore
# policy comes from the trusted base, just like the Gitleaks configuration.
for language in rust shell; do
    rc=0
    (cd "$subject" && SHELL_IGNORE_FILE="$scan_dir/.shell-secrets-ignore" \
        timeout --signal=TERM --kill-after=10s 90s bash "$script_dir/$language-supplement.sh") || rc=$?
    printf 'supplement=%s exit=%s\n' "$language" "$rc"
    case $rc in
        0) ;;
        1) [[ $verdict == 2 ]] || verdict=1 ;;
        *) verdict=2 ;;
    esac
done
printf 'verdict=%s (0=passed, 1=findings, 2=infrastructure/configuration/timeout)\n' "$verdict"
exit "$verdict"
