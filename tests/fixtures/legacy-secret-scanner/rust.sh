#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# FROZEN TEST ORACLE ONLY: exact run body at standards
# 74d2f66f575246cf6e313ae7775f44df6e097ff2. May log synthetic fixture content.
# Not a production scanner; run only against test-generated repositories.
TODAY="${RUST_TODAY:-$(date -u +%Y-%m-%d)}"

# An unparseable cutoff would pick the warn branch forever, silently
# disarming the widened scan. Refuse to run instead.
require_date() {
  case "$2" in
    [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]) : ;;
    *) echo "::error::rust-secrets: $1='$2' is not YYYY-MM-DD."
       echo "Refusing to run: an unparseable cutoff would disarm this gate."
       exit 1 ;;
  esac
}
require_date ENFORCE_RUST_WIDE_SCAN_FROM "$ENFORCE_RUST_WIDE_SCAN_FROM"
require_date RUST_TODAY "$TODAY"

if ! find . -name Cargo.toml -not -path './target/*' -print -quit | grep -q .; then
  echo 'No Cargo.toml found — skipping Rust secrets check'
  exit 0
fi

# Scan every .rs file, not just ./src. A Cargo workspace keeps its
# code in crates/*/src, and the previous `grep … src/` matched
# nothing there: grep exits 2 on a missing directory, which the `if`
# read as "clean". Measured 2026-07-21 across the 64 Rust repos in
# the estate re-pin sweep: 8 (12.5%) have no root src/ and were
# therefore never scanned at all — a planted secret in
# crates/core/src/lib.rs passed this job silently.
mapfile -t FILES < <(find . -name '*.rs' \
  -not -path './target/*' -not -path '*/target/*' \
  -not -path './vendor/*' -not -path '*/vendor/*' \
  -not -path './.git/*' -print)
if [ ${#FILES[@]} -eq 0 ]; then
  echo 'Cargo.toml present but no .rs files — nothing to scan'
  exit 0
fi
echo "Scanning ${#FILES[@]} Rust file(s)."

# Each pattern requires an assignment DIRECTLY to a string literal of
# meaningful length. The previous forms matched `= ... "` — a quote
# anywhere after an equals — which flagged code that hardcodes
# nothing at all. Measured across the 64 Rust repos in the estate
# sweep, every one of these was a false positive:
#   let api_key = request["api_key"].as_str().unwrap_or("")  (lookup)
#   let api_key_file = temp_dir.path().join("config.js")     (path)
#   Query::new("Here's my api_key=sk-12345")                 (a demo)
# A credential shorter than 8 characters is not a credential either.
# `static` is accepted alongside `const`: the old `const.*KEY` form
# missed `static AUTH_KEY: &str = "…"`, a genuine hardcoded secret
# (caught by canary, not by inspection).
PATTERNS=(
  '(const|static)[[:space:]]+(mut[[:space:]]+)?[A-Za-z0-9_]*SECRET[A-Za-z0-9_]*[[:space:]]*(:[^=]*)?=[[:space:]]*b?"[^"]{8,}"'
  '(const|static)[[:space:]]+(mut[[:space:]]+)?[A-Za-z0-9_]*KEY[A-Za-z0-9_]*[[:space:]]*(:[^=]*)?=[[:space:]]*b?"[a-zA-Z0-9]{16,}"'
  '(const|static)[[:space:]]+(mut[[:space:]]+)?[A-Za-z0-9_]*TOKEN[A-Za-z0-9_]*[[:space:]]*(:[^=]*)?=[[:space:]]*b?"[^"]{8,}"'
  '(let|static)[[:space:]]+(mut[[:space:]]+)?[a-z0-9_]*api_key[a-z0-9_]*[[:space:]]*(:[^=]*)?=[[:space:]]*b?"[^"]{8,}"'
  'HMAC.*"[a-fA-F0-9]{32,}"'
  '[a-z0-9_]*password[a-z0-9_]*[[:space:]]*(:[^=]*)?=[[:space:]]*b?"[^"]{8,}"'
)

# Exemptions, mirroring the four layers already documented on
# shell-secrets. All match on the VALUE or on an explicit pragma,
# never on a file path: a path-based exemption would blind the job
# to a genuine secret in the same file (the failure mode the
# .gitleaks.toml allowlist was rewritten to avoid, standards#512).
#
#  1. env-lookup RHS — `env::var("NAME")` IS the practice this job
#     exists to enforce, so flagging it fails the correct code. This
#     was the sole rust-secrets failure in the 201-repo sweep:
#     cloudguard-server src/main.rs:59,
#     `let api_key = env::var("CLOUDGUARD_API_KEY").ok();`. Anchored
#     to the assignment and stopped at `;`, so a literal secret with
#     an unrelated env::var mention later on the line still trips.
#  2. URL values — an OAuth endpoint is public and not a credential.
#     `const MS_TOKEN_URL = "https://login.microsoftonline.com/…"`
#     tripped `const.*TOKEN.*=.*"` in four places in one repo.
#  3. comment lines — documentation of a pattern is not a live secret.
#  4. inline pragma `// scanner-allow: rust-secrets`.
COMMENT='^[^:]*:[0-9][0-9]*:[[:space:]]*(//|/\*|\*)'
ENV_RHS='=[^;]*(env::var|env::var_os|std::env|env!\(|option_env!\(|from_env|dotenv)'
URL_RHS='=[[:space:]]*b?"(https?|wss?|ftp)://'
PRAGMA='scanner-allow:[[:space:]]*rust-secrets'

blocking=0
advisory=0
for pattern in "${PATTERNS[@]}"; do
  hits="$(grep -nHE "$pattern" "${FILES[@]}" 2>/dev/null \
    | grep -vE "$COMMENT" \
    | grep -vE "$ENV_RHS" \
    | grep -vE "$URL_RHS" \
    | grep -vE "$PRAGMA" || [ $? -eq 1 ])"
  [ -n "$hits" ] || continue

  # ./src was the only path the previous version scanned. Hits there
  # keep blocking exactly as before — no regression. Hits outside it
  # are newly visible, so they warn until the cutoff rather than
  # reddening repos that were never actually being scanned.
  old_scope="$(printf '%s\n' "$hits" | grep -E '^\./src/' || [ $? -eq 1 ])"
  new_scope="$(printf '%s\n' "$hits" | grep -vE '^\./src/' || [ $? -eq 1 ])"

  if [ -n "$old_scope" ]; then
    printf '%s\n' "$old_scope"
    echo "WARNING: Potential hardcoded secret found matching: $pattern"
    blocking=1
  fi
  if [ -n "$new_scope" ]; then
    printf '%s\n' "$new_scope"
    if [[ "$TODAY" < "$ENFORCE_RUST_WIDE_SCAN_FROM" ]]; then
      echo "::warning::Potential hardcoded secret outside ./src matching:" \
           "$pattern — becomes BLOCKING on $ENFORCE_RUST_WIDE_SCAN_FROM (today is $TODAY)."
      advisory=1
    else
      echo "WARNING: Potential hardcoded secret found matching: $pattern"
      blocking=1
    fi
  fi
done

if [ "$blocking" -eq 1 ]; then
  echo "::error::Potential hardcoded secrets detected. Use environment variables instead."
  exit 1
fi
if [ "$advisory" -eq 1 ]; then
  # Never claim a clean pass while findings are outstanding.
  echo "NOT YET ENFORCED: findings outside ./src are advisory until $ENFORCE_RUST_WIDE_SCAN_FROM."
  exit 0
fi
echo 'No hardcoded secrets detected in Rust sources.'

