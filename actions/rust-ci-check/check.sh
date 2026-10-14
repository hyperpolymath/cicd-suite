#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check.sh — the strict Rust gate, one phase per invocation.
#
#   RUST_GATE_PHASE=check   cargo check --locked, cargo fmt --check, cargo clippy -D warnings
#   RUST_GATE_PHASE=test    cargo test --locked (all targets) AND cargo test --doc
#   RUST_GATE_PHASE=doc     cargo doc --no-deps --document-private-items, RUSTDOCFLAGS=-D warnings
#   RUST_GATE_PHASE=msrv    cargo +<MSRV> check --locked (the declared rust-version must build)
#
# What "strict" means here, and why each rule exists:
#
#   * `--locked` on every cargo call. Cargo.lock is a hard constraint: a lock
#     that needs updating fails the gate instead of being re-resolved in CI
#     (standards#295; the echidna#92 24-hour masked break).
#   * A MISSING Cargo.lock fails before cargo runs, with the fix named. Without
#     a lock `--locked` cannot hold and every run resolves afresh.
#   * `RUSTFLAGS=-D warnings` (and RUSTDOCFLAGS) for every compile, not only
#     clippy's: a rustc warning in a test target is a defect the old gate let
#     through because only `cargo clippy -- -D warnings` denied anything.
#   * Doctests run as their own step. `cargo test --all-targets` does NOT run
#     doctests (cargo's documented behaviour), so the previous gate never
#     executed a single `///` example. The one tolerated outcome is a
#     workspace with no library target at all — cargo reports exactly
#     "no library targets found" and nothing else — which is a fact about the
#     crate, not a swallowed failure, and is printed as a ::notice.
#   * `cargo doc` with warnings denied: a broken intra-doc link is a defect.
#   * The MSRV phase builds with the toolchain the manifest PROMISES. A crate
#     that says `rust-version = "1.74"` and needs 1.80 lies to every consumer.
#
# No step here may swallow an exit code. If a command cannot run (tool
# missing), that is exit 2 — "no check was performed" — never a pass.
#
# Env: WORKING_DIRECTORY (default "."), CHECK_ARGS, CLIPPY_ARGS, TEST_ARGS,
#      DOCTESTS (true|false, default true), DENY_WARNINGS (true|false,
#      default true), MSRV (msrv phase only).
set -uo pipefail

phase="${RUST_GATE_PHASE:?RUST_GATE_PHASE is required: check|test|doc|msrv}"
dir="${WORKING_DIRECTORY:-.}"
check_args="${CHECK_ARGS:---all-targets}"
clippy_args="${CLIPPY_ARGS:---all-targets -- -D warnings}"
test_args="${TEST_ARGS:---all-targets}"
doctests="${DOCTESTS:-true}"
deny_warnings="${DENY_WARNINGS:-true}"

fail=0
err() { echo "::error::rust-ci-check[$phase]: $*" >&2; fail=1; }

command -v cargo >/dev/null 2>&1 || {
  echo "::error::rust-ci-check[$phase]: cargo is not on PATH — NO CHECK WAS PERFORMED. The workflow must install a toolchain before this step." >&2
  exit 2
}
[ -f "$dir/Cargo.toml" ] || {
  echo "::error::rust-ci-check[$phase]: $dir/Cargo.toml not found — NO CHECK WAS PERFORMED. Set working_directory to the crate root." >&2
  exit 2
}
cd "$dir" || { echo "::error::rust-ci-check[$phase]: cannot enter $dir — NO CHECK WAS PERFORMED." >&2; exit 2; }

if [ ! -f Cargo.lock ]; then
  echo "::error file=$dir/Cargo.toml::Cargo.lock is not committed. The gate runs every cargo command with --locked so dependency drift fails the first push it happens; without a lock there is nothing to hold. Run 'cargo generate-lockfile', commit Cargo.lock, and push." >&2
  exit 1
fi

if [ "$deny_warnings" = true ]; then
  export RUSTFLAGS="${RUSTFLAGS:-} -D warnings"
  export RUSTDOCFLAGS="${RUSTDOCFLAGS:-} -D warnings"
fi
export CARGO_TERM_COLOR="${CARGO_TERM_COLOR:-always}"

run() { # <label> <cmd...>
  local label="$1"; shift
  echo "::group::$label — $*"
  if "$@"; then
    echo "::endgroup::"
    echo "ok: $label"
  else
    local rc=$?
    echo "::endgroup::"
    err "$label failed (exit $rc): $*"
  fi
}

case "$phase" in
  check)
    # shellcheck disable=SC2086 # args are deliberately word-split
    run "cargo check" cargo check --locked $check_args
    run "cargo fmt" cargo fmt --all --check
    # shellcheck disable=SC2086
    run "cargo clippy" cargo clippy --locked $clippy_args
    ;;
  test)
    # shellcheck disable=SC2086
    run "cargo test" cargo test --locked $test_args
    if [ "$doctests" = true ]; then
      echo "::group::cargo doctests — cargo test --locked --doc --workspace"
      out="$(mktemp)"
      if cargo test --locked --doc --workspace 2>&1 | tee "$out"; then
        echo "::endgroup::"
        echo "ok: cargo doctests"
      else
        echo "::endgroup::"
        # The ONE tolerated outcome: no library target anywhere, so there are
        # no doctests to run. Cargo says exactly this and nothing else.
        if grep -qE '^error: no library targets found' "$out" \
           && [ "$(grep -cE '^error' "$out" || true)" -eq 1 ]; then
          echo "::notice::rust-ci-check[test]: no library target in the workspace, so there are no doctests to run (cargo: 'no library targets found'). This is a fact about the crate, not a skipped check."
        else
          err "cargo doctests failed: cargo test --locked --doc --workspace"
        fi
      fi
      rm -f "$out"
    else
      echo "::warning::rust-ci-check[test]: doctests DISABLED by the caller (doctests: false). '///' examples are not executed by --all-targets; this gate is weaker than the default."
    fi
    ;;
  doc)
    run "cargo doc" cargo doc --locked --no-deps --document-private-items --workspace
    ;;
  msrv)
    msrv="${MSRV:-}"
    [ -n "$msrv" ] || { echo "::error::rust-ci-check[msrv]: MSRV is empty — NO CHECK WAS PERFORMED. The msrv job must only run when resolve.sh found a rust-version." >&2; exit 2; }
    if ! rustup run "$msrv" rustc --version >/dev/null 2>&1; then
      echo "::error::rust-ci-check[msrv]: toolchain $msrv is not installed — NO CHECK WAS PERFORMED. The workflow installs the declared rust-version before this step." >&2
      exit 2
    fi
    # shellcheck disable=SC2086
    run "cargo +$msrv check (declared rust-version)" cargo "+$msrv" check --locked $check_args
    ;;
  *)
    echo "::error::rust-ci-check: unknown phase '$phase' (check|test|doc|msrv)" >&2
    exit 2
    ;;
esac

if [ "$fail" -ne 0 ]; then
  echo "::error::rust-ci-check[$phase]: FAILED — see the annotated step(s) above. Fix the code; never weaken the flags (no --no-locked, no -A warnings, no continue-on-error)."
  exit 1
fi
echo "rust-ci-check[$phase]: all checks passed."
