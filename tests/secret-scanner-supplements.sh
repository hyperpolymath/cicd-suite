#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Differential empirical evidence, not a universal proof of equivalence.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Synthetic value never issued by a provider. Assemble rather than commit a token.
value=$(printf '%s%s' N7cR2mQ9aB4dE6fG 8hJ1kL3pS5tV0wX2)
count=0
case_check() {
    local language=$1 expected=$2 label=$3 text=$4 ignore=${5:-} actual=0 legacy=0
    count=$((count+1))
    local dir="$tmp/$count"
    mkdir -p "$dir/bin" "$dir/crates/core/src"
    if [[ $language == rust ]]; then
        echo '[workspace]' >"$dir/Cargo.toml"
        printf '%s\n' "$text" >"$dir/crates/core/src/lib.rs"
    else
        printf '%s\n' "$text" >"$dir/bin/control.sh"
        [[ -z $ignore ]] || printf '%s\n' "$ignore" >"$dir/.shell-secrets-ignore"
    fi
    (cd "$dir" && bash "$root/actions/secret-scan-check/$language-supplement.sh") >"$tmp/new.log" 2>&1 || actual=$?
    # Match the old Actions shell and its explicitly set cutoff. Oracle output
    # stays inside the private temporary directory and is never printed.
    (cd "$dir" && ENFORCE_RUST_WIDE_SCAN_FROM=2026-08-21 RUST_TODAY=2026-10-30 \
        bash -e "$root/tests/fixtures/legacy-secret-scanner/$language.sh") >"$tmp/legacy.log" 2>&1 || legacy=$?
    if [[ $actual != "$expected" || $legacy != "$expected" ]]; then
        printf 'FAIL %s: wanted=%s port=%s oracle=%s\n' "$label" "$expected" "$actual" "$legacy"
        exit 1
    fi
    if grep -Fq "$value" "$tmp/new.log"; then
        echo "FAIL $label: scanner printed synthetic credential content"; exit 1
    fi
    echo "ok: $label (port=$actual, pinned oracle=$legacy, values redacted)"
}
for name in SECRET KEY TOKEN; do
    case_check rust 1 "workspace Rust const $name" "const AUTH_$name: &str = \"$value\";"
    case_check rust 1 "workspace Rust static $name" "static AUTH_$name: &str = \"$value\";"
done
case_check rust 1 'Rust api_key literal' "let api_key = \"$value\";"
case_check rust 1 'Rust password literal' "let password = \"$value\";"
case_check rust 1 'Rust HMAC hex literal' 'let key = HMAC("a8c2f6b4d9e7a1c3f5b0d8e6a4c2f9b7");'
case_check rust 0 'Rust environment lookup' 'let api_key = std::env::var("SERVICE_API_KEY");'
case_check rust 0 'Rust URL value' 'const TOKEN_URL: &str = "https://service.example.invalid/oauth/token";'
case_check rust 0 'Rust comment suppression retained' "// const AUTH_SECRET: &str = \"$value\";"
case_check rust 0 'Rust explicit pragma retained' "const AUTH_SECRET: &str = \"$value\"; // scanner-allow: rust-secrets"
case_check rust 0 'Rust short non-credential' 'const AUTH_SECRET: &str = "short";'
for name in TOKEN API_KEY SECRET PASSWORD; do
    case_check shell 1 "shell $name literal" "export SERVICE_$name=\"$value\""
done
case_check shell 1 'shell exact PASSWORD assignment' "PASSWORD=\"$value\""
case_check shell 0 'shell environment lookup' 'export SERVICE_TOKEN="${SERVICE_TOKEN:?required}"'
case_check shell 0 'shell comment suppression retained' "# export SERVICE_TOKEN=\"$value\""
case_check shell 0 'shell same-line pragma retained' "export SERVICE_TOKEN=\"$value\" # scanner-allow: shell-secrets"
case_check shell 0 'shell preceding pragma retained' "$(printf '# scanner-allow: shell-secrets\nexport SERVICE_TOKEN="%s"' "$value")"
case_check shell 0 'shell hypatia pragma retained' "export SERVICE_TOKEN=\"$value\" # hypatia: allow security_errors/secret_detected"
case_check shell 0 'shell repository ignore retained' "export SERVICE_TOKEN=\"$value\"" 'bin/*.sh'
case_check shell 0 'shell short non-credential' 'export SERVICE_TOKEN="short"'
echo "passed $count differential fixtures; this is not a whole-estate coverage claim"
# Security hardening intentionally beyond legacy equivalence.
mkdir -p "$tmp/trust/bin" "$tmp/base"
printf 'export SERVICE_TOKEN="%s"\n' "$value" >"$tmp/trust/bin/control.sh"
echo 'bin/*.sh' >"$tmp/trust/.shell-secrets-ignore"
rc=0
(cd "$tmp/trust" && SHELL_IGNORE_FILE="$tmp/base/.shell-secrets-ignore" \
    bash "$root/actions/secret-scan-check/shell-supplement.sh") >"$tmp/new.log" 2>&1 || rc=$?
[[ $rc == 1 ]] && ! grep -Fq "$value" "$tmp/new.log"
echo 'ok: subject-added ignore cannot replace explicit trusted-base policy'
mv "$tmp/trust/bin/control.sh" "$tmp/trust/bin/ambiguous:name.sh"
rm "$tmp/trust/.shell-secrets-ignore"
rc=0
(cd "$tmp/trust" && bash "$root/actions/secret-scan-check/shell-supplement.sh") >"$tmp/new.log" 2>&1 || rc=$?
[[ $rc == 2 ]] && ! grep -Fq "$value" "$tmp/new.log"
echo 'ok: ambiguous shell location refuses arithmetic parsing and leaks no content'
mkdir -p "$tmp/redact/crates"
echo '[workspace]' >"$tmp/redact/Cargo.toml"
printf 'const AUTH_SECRET: &str = "%s";\n' "$value" >"$tmp/redact/crates/colon:name.rs"
rc=0
(cd "$tmp/redact" && bash "$root/actions/secret-scan-check/rust-supplement.sh") >"$tmp/new.log" 2>&1 || rc=$?
[[ $rc == 1 ]] && ! grep -Fq "$value" "$tmp/new.log"
echo 'ok: Rust redaction survives colon-containing filenames'
mkdir "$tmp/broken-tools"
printf '#!/usr/bin/env bash\nexit 2\n' >"$tmp/broken-tools/find"
printf '#!/usr/bin/env bash\nexit 2\n' >"$tmp/broken-tools/grep"
chmod +x "$tmp/broken-tools/"*
for language in rust shell; do
    rc=0
    (cd "$tmp/redact" && PATH="$tmp/broken-tools:$PATH" \
        bash "$root/actions/secret-scan-check/$language-supplement.sh") >"$tmp/new.log" 2>&1 || rc=$?
    [[ $rc == 2 ]]
    echo "ok: $language population/tool error is exit 2, not clean or not-applicable"
done
