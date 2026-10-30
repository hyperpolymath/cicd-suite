#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# FROZEN TEST ORACLE ONLY: exact run body at standards
# 74d2f66f575246cf6e313ae7775f44df6e097ff2. May log synthetic fixture content.
# Not a production scanner; run only against test-generated repositories.
# Patterns: an `export FOO=` or `FOO=` with a quoted literal of meaningful length.
# Restricted to *_TOKEN / *_KEY / *_SECRET / PASSWORD to keep false-positives low.
PATTERNS=(
  '(export[[:space:]]+)?[A-Z_]*TOKEN[A-Z_]*=["'"'"'][A-Za-z0-9_./+=-]{20,}["'"'"']'
  '(export[[:space:]]+)?[A-Z_]*API_KEY[A-Z_]*=["'"'"'][A-Za-z0-9_./+=-]{20,}["'"'"']'
  '(export[[:space:]]+)?[A-Z_]*SECRET[A-Z_]*=["'"'"'][A-Za-z0-9_./+=-]{16,}["'"'"']'
  '(export[[:space:]]+)?PASSWORD=["'"'"'][^"'"'"']{6,}["'"'"']'
)

# Inline pragma patterns — suppress a hit when found on the same or
# immediately preceding line.
PRAGMA_RE='(scanner-allow:[[:space:]]*shell-secrets|hypatia:[[:space:]]*allow[[:space:]]+security_errors/secret_detected)'

# Param-expansion RHS pattern — assignments whose value is a variable
# reference rather than a literal are never real secrets.
# Matches: ="$VAR"  ="${VAR}"  ="${VAR:-…}"  ="${VAR:?…}"  ='${VAR}'  =$VAR
PARAM_EXPANSION_RE='=['"'"'"'"'"']?\$\{?[A-Za-z_][A-Za-z0-9_]*(:[?-][^}]*)?\}?['"'"'"'"'"']?[[:space:]]*(#.*)?$'

# Load per-repo ignore globs from .shell-secrets-ignore if present.
IGNORE_GLOBS=()
if [[ -f .shell-secrets-ignore ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip blank lines and comments
    [[ -z "$line" || "$line" == \#* ]] && continue
    IGNORE_GLOBS+=("$line")
  done < .shell-secrets-ignore
fi

# is_ignored <filepath> — returns 0 (true) if path matches any ignore glob.
is_ignored() {
  local path="$1"
  for glob in "${IGNORE_GLOBS[@]}"; do
    # Use bash pattern matching; strip leading ./ for consistency.
    local stripped="${path#./}"
    # shellcheck disable=SC2254
    if [[ "$stripped" == $glob ]]; then
      return 0
    fi
  done
  return 1
}

found=0
for pattern in "${PATTERNS[@]}"; do
  # Collect raw matches: filepath:lineno:content
  while IFS= read -r raw_match; do
    [[ -z "$raw_match" ]] && continue

    # Parse filepath and line number from grep -n output (file:line:content).
    filepath="${raw_match%%:*}"
    rest="${raw_match#*:}"
    lineno="${rest%%:*}"
    content="${rest#*:}"

    # Exemption 1: .shell-secrets-ignore glob match on the file path.
    if is_ignored "$filepath"; then
      echo "  [skip] $filepath:$lineno — matched .shell-secrets-ignore glob"
      continue
    fi

    # Exemption 2: param-expansion RHS — value is a variable reference, not a literal.
    if echo "$content" | grep -qE "$PARAM_EXPANSION_RE"; then
      echo "  [skip] $filepath:$lineno — param-expansion (not a literal value)"
      continue
    fi

    # Exemption 3: comment line — leading non-whitespace char is '#'.
    # Comment lines cannot hold real secrets; they only document patterns.
    if echo "$content" | grep -qE '^[[:space:]]*#'; then
      echo "  [skip] $filepath:$lineno — comment line (not executable)"
      continue
    fi

    # Exemption 5: inline pragma on same line.
    if echo "$content" | grep -qE "$PRAGMA_RE"; then
      echo "  [skip] $filepath:$lineno — inline pragma on same line"
      continue
    fi

    # Exemption 6: inline pragma on the immediately preceding line.
    if [[ "$lineno" -gt 1 ]]; then
      prev_line=$(sed -n "$((lineno - 1))p" "$filepath" 2>/dev/null)
      if echo "$prev_line" | grep -qE "$PRAGMA_RE"; then
        echo "  [skip] $filepath:$lineno — pragma on preceding line"
        continue
      fi
    fi

    echo "::warning::$filepath:$lineno: $content"
    echo "  Potential hardcoded secret matching pattern: $pattern"
    found=1

  done < <(grep -rnE --include='*.sh' --include='*.bash' \
             --exclude-dir='.git' --exclude-dir='node_modules' --exclude-dir='target' \
             "$pattern" . 2>/dev/null || [ $? -eq 1 ])
done

if [ $found -eq 1 ]; then
  echo "::error::Hardcoded secret detected in a shell script. Read the value from the environment (e.g. \"\${MY_TOKEN:?}\") and supply it via a repo or org secret."
  exit 1
fi
