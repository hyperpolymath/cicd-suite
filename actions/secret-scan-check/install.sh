#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Pinned Linux x64 install; no floating release resolution or cache-as-proof.
set -euo pipefail
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'unsupported runner architecture' >&2; exit 2; }
destination=${1:?destination directory required}
mkdir -p "$destination"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
version=8.30.1
checksum=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
curl --proto '=https' --proto-redir '=https' --fail --silent --show-error --location --connect-timeout 10 --max-time 90 \
    --retry 2 --retry-max-time 180 \
    "https://github.com/gitleaks/gitleaks/releases/download/v${version}/gitleaks_${version}_linux_x64.tar.gz" \
    -o "$tmp/gitleaks.tar.gz"
printf '%s  %s\n' "$checksum" "$tmp/gitleaks.tar.gz" | sha256sum -c -
tar -xzf "$tmp/gitleaks.tar.gz" -C "$tmp" gitleaks
install -m 0755 "$tmp/gitleaks" "$destination/gitleaks"
"$destination/gitleaks" version
