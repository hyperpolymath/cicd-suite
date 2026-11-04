#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Install only the committed official binary identity, before token access.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
manifest="$root/config/actions-lock-recovery-tool.json"
[[ -n "${RUNNER_TEMP:-}" && -n "${GITHUB_ENV:-}" ]] \
  || { echo 'Recovery tool installation requires disposable runner paths'; exit 2; }
[[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" && -z "${GH_ENTERPRISE_TOKEN:-}" && -z "${GITHUB_ENTERPRISE_TOKEN:-}" ]] \
  || { echo 'Recovery tool installation must run without GitHub credentials'; exit 2; }
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] \
  || { echo 'No qualified recovery binary for this platform'; exit 2; }
for tool in curl jq sha256sum gh readlink; do
  command -v "$tool" >/dev/null || { echo "$tool unavailable; installation NOT RUN"; exit 2; }
done
jq -e '
  .schema_version == 1 and .repository == "github/gh-actions-lock" and
  .release_tag == "v0.2.0" and .asset_name == "linux-amd64" and
  .download_url == "https://github.com/github/gh-actions-lock/releases/download/v0.2.0/linux-amd64" and
  (.sha256 | test("^[0-9a-f]{64}$")) and (.bytes | type == "number" and . > 0)
' "$manifest" >/dev/null || { echo 'Recovery tool identity manifest is invalid'; exit 2; }
expected=$(jq -r .sha256 "$manifest")
expected_bytes=$(jq -r .bytes "$manifest")
url=$(jq -r .download_url "$manifest")
install_root=$(mktemp -d "$RUNNER_TEMP/actions-lock-tool.XXXXXX")
installed=false
trap '[[ "$installed" == true ]] || rm -rf -- "$install_root"' EXIT
tool_dir="$install_root/gh-actions-lock"
mkdir "$tool_dir"
binary="$tool_dir/gh-actions-lock"
curl --fail --location --retry 2 --connect-timeout 10 --max-time 90 \
  --proto '=https' --output "$binary.download" "$url" \
  || { echo 'Official recovery binary download failed'; exit 2; }
actual=$(sha256sum "$binary.download" | cut -d ' ' -f1)
[[ "$actual" == "$expected" && $(wc -c < "$binary.download") -eq "$expected_bytes" ]] \
  || { echo 'Recovery binary identity mismatch; no downloaded code was executed'; exit 2; }
mv -- "$binary.download" "$binary"
chmod 700 "$binary"

# GH_CONFIG_DIR alone does not isolate extension storage. The official CLI
# stores extensions under XDG_DATA_HOME/gh; keep both within this fresh tree.
export GH_CONFIG_DIR="$install_root/config" XDG_DATA_HOME="$install_root/data"
export GH_NO_UPDATE_NOTIFIER=1 GH_NO_EXTENSION_UPDATE_NOTIFIER=1
(cd "$tool_dir" && gh extension install .)
registered="$XDG_DATA_HOME/gh/extensions/gh-actions-lock/gh-actions-lock"
[[ $(readlink -f "$registered") == "$binary" ]] \
  || { echo 'Registered recovery extension is not the verified binary'; exit 2; }
version=$(gh actions-lock --version)
[[ "$version" == 'actions-lock version v0.2.0' ]] \
  || { echo 'Verified recovery tool reported an unexpected version'; exit 2; }
printf 'RECOVERY_ACTIONS_LOCK_BIN=%s\nGH_CONFIG_DIR=%s\nXDG_DATA_HOME=%s\nGH_NO_UPDATE_NOTIFIER=1\nGH_NO_EXTENSION_UPDATE_NOTIFIER=1\n' \
  "$binary" "$GH_CONFIG_DIR" "$XDG_DATA_HOME" >> "$GITHUB_ENV"
installed=true
echo "Official recovery binary verified: SHA256 $actual ($version)"
