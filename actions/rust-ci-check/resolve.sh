#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# resolve.sh — the facts a Rust gate needs BEFORE any toolchain exists.
#
# Prints `key=value` lines (the $GITHUB_OUTPUT shape) on stdout:
#
#   has_cargo         true|false   <dir>/Cargo.toml exists
#   toolchain         <channel>    NEVER empty when has_cargo=true (see below)
#   toolchain_source  input|rust-toolchain.toml|rust-toolchain|default
#   msrv              <semver>|""  `rust-version` declared at <dir>/Cargo.toml
#   has_lock          true|false   <dir>/Cargo.lock exists (`--locked` needs it)
#   has_deny_toml     true|false   <dir>/deny.toml exists (licence policy is
#                                  owner-authored; the gate never invents one)
#
# WHY THE TOOLCHAIN IS RESOLVED HERE AND NOT LEFT TO THE ACTION
#
# `dtolnay/rust-toolchain@<tag>` reads its toolchain from the tag name, so
# `@stable` works with no `toolchain:` input. The estate pins by full SHA, and
# a SHA carries no version: the action's "parse toolchain version" step then
# exits 1 with "'toolchain' is a required input" before cargo runs. That is
# the failure every `rust-ci / Cargo check + clippy + fmt` showed from
# 2026-09-29 (plasma-parser-writer#105, run 38564229091) — six seconds, no
# compiler, no code checked. The gate therefore computes the channel itself
# and REFUSES to continue with an empty value: an empty toolchain is a
# configuration defect, never a "use whatever is there".
#
# Resolution order for `toolchain` when TOOLCHAIN is "auto" (the default):
#   1. <dir>/rust-toolchain.toml   `channel = "..."` under [toolchain]
#   2. <dir>/rust-toolchain        the bare channel on the first line
#   3. "stable"
# An explicit TOOLCHAIN other than "auto" wins, and a disagreeing toolchain
# file is reported as a ::warning so the drift is visible, not silent.
#
# Env: WORKING_DIRECTORY (default "."), TOOLCHAIN (default "auto").
set -uo pipefail

dir="${WORKING_DIRECTORY:-.}"
requested="${TOOLCHAIN:-auto}"

emit() { printf '%s=%s\n' "$1" "$2"; }

if [ ! -f "$dir/Cargo.toml" ]; then
  emit has_cargo false
  emit toolchain ""
  emit toolchain_source none
  emit msrv ""
  emit has_lock false
  emit has_deny_toml false
  exit 0
fi
emit has_cargo true

file_channel=""
file_source=""
if [ -f "$dir/rust-toolchain.toml" ]; then
  # `channel = "nightly-2026-08-03"` — first such key wins; quotes either style.
  file_channel="$(sed -nE 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*["'"'"']([^"'"'"']+)["'"'"'].*$/\1/p' \
                    "$dir/rust-toolchain.toml" | head -n 1 || true)"
  file_source="rust-toolchain.toml"
elif [ -f "$dir/rust-toolchain" ]; then
  file_channel="$(sed -nE '1s/^[[:space:]]*([^[:space:]#]+).*$/\1/p' "$dir/rust-toolchain" || true)"
  file_source="rust-toolchain"
fi

# A toolchain file that is present but names no channel is the same defect as
# the missing input — refuse rather than fall through to a guess.
if [ -n "$file_source" ] && [ -z "$file_channel" ]; then
  echo "::error file=$dir/$file_source::rust-ci-check: $file_source exists but names no channel — resolved toolchain is EMPTY. An empty toolchain is how the SHA-pinned dtolnay/rust-toolchain died with \"'toolchain' is a required input\" estate-wide. Name a channel, or delete the file." >&2
  exit 1
fi

toolchain=""
source=""
case "$requested" in
  ""|auto)
    if [ -n "$file_channel" ]; then
      toolchain="$file_channel"; source="$file_source"
    else
      toolchain="stable"; source="default"
    fi
    ;;
  *)
    toolchain="$requested"; source="input"
    if [ -n "$file_channel" ] && [ "$file_channel" != "$requested" ]; then
      echo "::warning file=$dir/$file_source::toolchain input '$requested' overrides $file_source channel '$file_channel'; the gate runs '$requested'. Remove one or make them agree." >&2
    fi
    ;;
esac

# A toolchain file that exists but names nothing is the same defect as the
# missing input: refuse rather than guess.
if [ -z "$toolchain" ]; then
  echo "::error file=$dir/${file_source:-Cargo.toml}::rust-ci-check: resolved toolchain is EMPTY (source: ${file_source:-input}). An empty toolchain is how the SHA-pinned dtolnay/rust-toolchain died with \"'toolchain' is a required input\" estate-wide. Name a channel in rust-toolchain.toml, or pass the gate's 'toolchain' input." >&2
  exit 1
fi
emit toolchain "$toolchain"
emit toolchain_source "$source"

# MSRV: `rust-version = "1.74"` under [package] or [workspace.package] of the
# root manifest. Members inherit the workspace value, so the root's claim is
# the one the gate checks; a member needing more fails the MSRV build, which
# is exactly the inconsistency worth surfacing.
msrv="$(sed -nE 's/^[[:space:]]*rust-version[[:space:]]*=[[:space:]]*["'"'"']([0-9]+(\.[0-9]+){1,2})["'"'"'].*$/\1/p' \
          "$dir/Cargo.toml" | head -n 1 || true)"
emit msrv "$msrv"

if [ -f "$dir/Cargo.lock" ]; then emit has_lock true; else emit has_lock false; fi
if [ -f "$dir/deny.toml" ]; then emit has_deny_toml true; else emit has_deny_toml false; fi
