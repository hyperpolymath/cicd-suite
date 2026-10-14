#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# verify-suite-checkout.sh — the reusable language gates read the SHA the
# caller pins them at back out of the caller's own workflow file, check this
# repository out at that SHA into .cicd-suite/ and run their scripts from
# there. This step proves the checkout IS that commit before any script runs.
#
# Why it must be a hard refusal: if the resolved SHA were ever empty,
# actions/checkout would silently take the DEFAULT BRANCH, and a caller
# pinned at a reviewed SHA would run whatever main holds today — the
# "@main would change the gate in every repository at once" hazard the
# full-SHA doctrine exists to prevent. An empty value is therefore
# exit 2: NO CHECK WAS PERFORMED.
#
# Env: EXPECTED (the SHA), SUITE_DIR (default .cicd-suite).
set -euo pipefail

expected="${EXPECTED:-}"
suite="${SUITE_DIR:-.cicd-suite}"

if ! printf '%s' "$expected" | grep -qE '^[0-9a-f]{40}$'; then
  echo "::error::cicd-suite: the caller's cicd-suite pin resolved to '${expected:-<empty>}', not a 40-hex commit — cannot pin the gate scripts. NO CHECK WAS PERFORMED." >&2
  exit 2
fi
[ -d "$suite/.git" ] || { echo "::error::cicd-suite: $suite is not a git checkout. NO CHECK WAS PERFORMED." >&2; exit 2; }
actual="$(git -C "$suite" rev-parse HEAD)"
if [ "$actual" != "$expected" ]; then
  echo "::error::cicd-suite: checkout is $actual but the reusable workflow is $expected. NO CHECK WAS PERFORMED." >&2
  exit 2
fi
for s in actions/rust-ci-check/check.sh actions/creusot-check/check.sh actions/spark-check/check.sh actions/kanren-check/check.sh; do
  [ -f "$suite/$s" ] || { echo "::error::cicd-suite: $s is missing at $expected. NO CHECK WAS PERFORMED." >&2; exit 2; }
done
echo "cicd-suite gate scripts pinned at $expected"
