#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

set -euo pipefail

root=${GITHUB_WORKSPACE:-.}
required=${AFFIRMATION_REQUIRED:-false}
aff_file=

for candidate in AFFIRMATION.adoc AFFIRMATION.md AFFIRMATION; do
  if [[ -f "$root/$candidate" ]]; then
    aff_file=$candidate
    break
  fi
done

if [[ -z "$aff_file" ]]; then
  if [[ "$required" == "true" ]]; then
    echo "::error::AFFIRMATION.adoc is required by the declared governance-tier capability."
    exit 1
  fi
  echo "::notice::AFFIRMATION is not applicable: governance-tier was not required."
  exit 0
fi

path=$root/$aff_file
echo "Found AFFIRMATION document: $aff_file"

substantive_lines=$(awk '!/^[[:space:]]*(#|\/\/|;|$)/ { count++ } END { print count + 0 }' "$path")
if (( substantive_lines < 5 )); then
  echo "::error::$aff_file has only $substantive_lines substantive lines; it is a stub, not an affirmation."
  exit 1
fi

if grep -qiE '\{\{|TODO: update|<PROJECT|YOUR_PROJECT|lorem ipsum|example\.com' "$path"; then
  echo "::error::$aff_file contains template placeholders."
  exit 1
fi

# The signature is the signature on the commit containing this content. Text
# such as "Signed:" inside the document proves nothing. Shallow checkouts may
# not contain the file-changing commit, so report that limitation honestly.
#
# Git can only classify a signature whose key it holds; without the key it
# reports E, which is indistinguishable from a broken check. Merges made on
# github.com (squash, merge, web edits) are signed by GitHub's web-flow key,
# so that key is vendored here and trusted inside a throwaway keyring. Callers
# may add PGP keys (AFFIRMATION_TRUSTED_GPG_KEYS, one armoured file) and SSH
# signers (AFFIRMATION_ALLOWED_SIGNERS, a git allowed_signers file; default
# .github/allowed_signers when the repository has one). Relative paths are
# resolved against the repository root.
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
trusted_gpg_keys=("$here/github-web-flow.gpg")
if [[ -n "${AFFIRMATION_TRUSTED_GPG_KEYS:-}" ]]; then
  extra_keys=$AFFIRMATION_TRUSTED_GPG_KEYS
  [[ "$extra_keys" == /* ]] || extra_keys=$root/$extra_keys
  trusted_gpg_keys+=("$extra_keys")
fi
allowed_signers=${AFFIRMATION_ALLOWED_SIGNERS:-}
if [[ -z "$allowed_signers" && -s "$root/.github/allowed_signers" ]]; then
  allowed_signers=$root/.github/allowed_signers
elif [[ -n "$allowed_signers" && "$allowed_signers" != /* ]]; then
  allowed_signers=$root/$allowed_signers
fi

# Build a private GnuPG home holding only the trusted keys, each given
# ultimate owner trust, and print its path. Prints nothing if gpg is absent
# or a key file cannot be imported, so verification falls back to no keys.
make_trusted_gnupg_home() {
  local home key_file
  command -v gpg >/dev/null 2>&1 || return 0
  home=$(mktemp -d)
  chmod 700 "$home"
  for key_file in "${trusted_gpg_keys[@]}"; do
    if [[ ! -s "$key_file" ]] \
      || ! gpg --batch --quiet --homedir "$home" --import "$key_file" >/dev/null 2>&1; then
      echo "::warning::Trusted PGP key file could not be imported: $key_file" >&2
      rm -rf -- "$home"
      return 0
    fi
  done
  gpg --batch --homedir "$home" --with-colons --fingerprint 2>/dev/null \
    | awk -F: '$1 == "fpr" { print $10 ":6:" }' \
    | gpg --batch --quiet --homedir "$home" --import-ownertrust >/dev/null 2>&1 || true
  printf '%s\n' "$home"
}

signature=N
signer=
last_update_ts=
if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  gnupg_home=$(make_trusted_gnupg_home)
  [[ -n "$gnupg_home" ]] || echo "::notice::No trusted PGP keys could be loaded; GitHub-signed commits cannot be checked."
  git_verify=(git -C "$root")
  if [[ -n "$allowed_signers" ]]; then
    git_verify+=(-c "gpg.ssh.allowedSignersFile=$allowed_signers")
  fi
  if [[ -n "$gnupg_home" ]]; then
    git_verify=(env "GNUPGHOME=$gnupg_home" "${git_verify[@]}")
  fi
  sig_line=$("${git_verify[@]}" log -1 --format='%G?%x09%GS' -- "$aff_file" 2>/dev/null || true)
  signature=${sig_line%%$'\t'*}
  if [[ "$sig_line" == *$'\t'* ]]; then
    signer=${sig_line#*$'\t'}
  fi
  last_update_ts=$(git -C "$root" log -1 --format='%at' -- "$aff_file" 2>/dev/null || true)
  if [[ -n "$gnupg_home" ]]; then
    rm -rf -- "$gnupg_home"
  fi
fi

case "$signature" in
  G) echo "Affirmation commit signature verified with a trusted key: ${signer:-unknown signer}."
     if [[ "$signer" == *"<noreply@github.com>"* ]]; then
       echo "::notice::GitHub signed this commit when it landed through github.com; an author signature, if any, is on the pull request's head commit."
     fi
     ;;
  U) echo "::notice::Affirmation commit has a valid signature from an untrusted or locally unknown key${signer:+: $signer}." ;;
  B|R|E) echo "::error::Affirmation commit signature is bad, revoked, or failed verification."; exit 1 ;;
  *) echo "::notice::Affirmation commit signature could not be verified from the available Git history." ;;
esac

# A dated affirmation is a frozen receipt, not a claim that remains current
# forever. Report age without invalidating historical evidence or forcing an
# empty monthly rewrite.
if [[ -n "$last_update_ts" ]]; then
  current_ts=$(date +%s)
  age_days=$(( (current_ts - last_update_ts) / 86400 ))
  if (( age_days > 28 )); then
    echo "::warning::$aff_file is a $age_days-day-old snapshot; verify its anchor before relying on it as current."
  else
    echo "$aff_file snapshot age: $age_days days."
  fi
fi

echo "AFFIRMATION document validation passed."
