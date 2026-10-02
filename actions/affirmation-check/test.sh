#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

GITHUB_WORKSPACE=$fixture AFFIRMATION_REQUIRED=false "$here/check.sh"

if GITHUB_WORKSPACE=$fixture AFFIRMATION_REQUIRED=true "$here/check.sh"; then
  echo "required-but-absent affirmation unexpectedly passed" >&2
  exit 1
fi

printf '= AFFIRMATION\n' > "$fixture/AFFIRMATION.adoc"
if GITHUB_WORKSPACE=$fixture AFFIRMATION_REQUIRED=true "$here/check.sh"; then
  echo "stub affirmation unexpectedly passed" >&2
  exit 1
fi

printf '%s\n' \
  '= AFFIRMATION — controlled fixture' \
  'This snapshot makes a falsifiable claim.' \
  'The claim is anchored to a named revision.' \
  'Tests were run and their scope is stated.' \
  'Unproved properties are not called proved.' \
  'Later revisions must be assessed separately.' \
  > "$fixture/AFFIRMATION.adoc"
GITHUB_WORKSPACE=$fixture AFFIRMATION_REQUIRED=true "$here/check.sh"


# Signature controls. Each verdict is planted with a throwaway key, so the
# checker is shown both to accept what it should and to refuse what it should.
# Print a minimal affirmation that passes the stub and placeholder checks.
substantive_affirmation() {
  printf '%s\n' \
    '= AFFIRMATION — controlled fixture' \
    'This snapshot makes a falsifiable claim.' \
    'The claim is anchored to a named revision.' \
    'Tests were run and their scope is stated.' \
    'Unproved properties are not called proved.' \
    'Later revisions must be assessed separately.'
}

# Create a git repository at $1 holding one commit of AFFIRMATION.adoc, with
# any extra `git -c` settings in the remaining arguments (used to sign it).
make_signed_repo() {
  local repo=$1
  shift
  git init -q "$repo"
  substantive_affirmation > "$repo/AFFIRMATION.adoc"
  git -C "$repo" add AFFIRMATION.adoc
  git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
    "$@" commit -q -m 'affirm'
}

# Run the checker on repository $1 with the remaining arguments as extra
# environment, capturing output in $fixture/out; returns the checker's status.
run_check() {
  local repo=$1
  shift
  env GITHUB_WORKSPACE="$repo" AFFIRMATION_REQUIRED=true "$@" "$here/check.sh" > "$fixture/out" 2>&1
}

if command -v gpg >/dev/null 2>&1; then
  vendored_fprs=$(gpg --batch --with-colons --import-options show-only --import "$here/github-web-flow.gpg" 2>/dev/null \
    | awk -F: '$1 == "fpr" { print $10 }' | sort | tr '\n' ' ')
  if [[ "$vendored_fprs" != "5DE3E0509C47EA3CF04A42D34AEE18F83AFDEB23 968479A1AFF927E37D1A566BB5690EEEBB952194 " ]]; then
    echo "vendored GitHub web-flow key has unexpected fingerprints: $vendored_fprs" >&2
    exit 1
  fi

  signer_home=$fixture/signer-gnupg
  mkdir -m 700 "$signer_home"
  GNUPGHOME=$signer_home gpg --batch --quiet --passphrase '' \
    --quick-generate-key 'Fixture <fixture@example.invalid>' ed25519 sign never
  GNUPGHOME=$signer_home gpg --batch --armor --export > "$fixture/fixture-key.asc"

  pgp_repo=$fixture/pgp
  GNUPGHOME=$signer_home make_signed_repo "$pgp_repo" -c commit.gpgsign=true \
    -c gpg.format=openpgp -c user.signingkey=fixture@example.invalid

  run_check "$pgp_repo" AFFIRMATION_TRUSTED_GPG_KEYS="$fixture/fixture-key.asc"
  if ! grep -q 'verified with a trusted key: Fixture <fixture@example.invalid>' "$fixture/out"; then
    cat "$fixture/out" >&2
    echo "PGP signature from a supplied trusted key was not verified" >&2
    exit 1
  fi

  if run_check "$pgp_repo"; then
    echo "PGP signature from an unsupplied key unexpectedly passed" >&2
    exit 1
  fi

  # Tamper with the signed commit's message so its signature no longer matches.
  tampered=$(git -C "$pgp_repo" cat-file commit HEAD | sed 's/^affirm$/affirm, altered/' \
    | git -C "$pgp_repo" hash-object -t commit -w --stdin)
  git -C "$pgp_repo" update-ref HEAD "$tampered"
  if run_check "$pgp_repo" AFFIRMATION_TRUSTED_GPG_KEYS="$fixture/fixture-key.asc"; then
    echo "tampered PGP signature unexpectedly passed" >&2
    exit 1
  fi
  if ! grep -q 'signature is bad' "$fixture/out"; then
    cat "$fixture/out" >&2
    echo "tampered PGP signature failed for the wrong reason" >&2
    exit 1
  fi

  if run_check "$pgp_repo" AFFIRMATION_TRUSTED_GPG_KEYS="$fixture/missing.asc"; then
    echo "missing trusted key file unexpectedly passed" >&2
    exit 1
  fi
  if ! grep -q 'could not be imported' "$fixture/out"; then
    cat "$fixture/out" >&2
    echo "missing trusted key file failed for the wrong reason" >&2
    exit 1
  fi
else
  echo "::warning::gpg is not installed; PGP signature controls were not run."
fi

if command -v ssh-keygen >/dev/null 2>&1; then
  ssh-keygen -q -t ed25519 -N '' -C fixture -f "$fixture/ssh-key"
  ssh_repo=$fixture/ssh
  make_signed_repo "$ssh_repo" -c commit.gpgsign=true -c gpg.format=ssh \
    -c user.signingkey="$fixture/ssh-key.pub"

  run_check "$ssh_repo"
  if ! grep -q 'untrusted or locally unknown key' "$fixture/out"; then
    cat "$fixture/out" >&2
    echo "SSH signature without allowed_signers was not reported as untrusted" >&2
    exit 1
  fi

  mkdir -p "$ssh_repo/.github"
  printf 'fixture@example.invalid %s\n' "$(cat "$fixture/ssh-key.pub")" > "$ssh_repo/.github/allowed_signers"
  run_check "$ssh_repo"
  if ! grep -q 'verified with a trusted key' "$fixture/out"; then
    cat "$fixture/out" >&2
    echo "SSH signature listed in .github/allowed_signers was not verified" >&2
    exit 1
  fi
else
  echo "::warning::ssh-keygen is not installed; SSH signature controls were not run."
fi

# A shallow checkout must say that the commit it found is only the history
# boundary; a full one must not.
history_repo=$fixture/history
make_signed_repo "$history_repo"
echo later > "$history_repo/LATER"
git -C "$history_repo" add LATER
git -C "$history_repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q -m later
run_check "$history_repo"
if grep -q 'history boundary' "$fixture/out"; then
  cat "$fixture/out" >&2
  echo "full history was reported as a shallow boundary" >&2
  exit 1
fi
git clone -q --depth 1 "file://$history_repo" "$fixture/shallow"
run_check "$fixture/shallow"
if ! grep -q 'history boundary' "$fixture/out"; then
  cat "$fixture/out" >&2
  echo "shallow boundary commit was not reported" >&2
  exit 1
fi
# Shallow, but the affirmation commit lies above the boundary: no notice.
echo 'The shallow fixture re-affirms the claim at a later commit.' >> "$history_repo/AFFIRMATION.adoc"
git -C "$history_repo" add AFFIRMATION.adoc
git -C "$history_repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q -m reaffirm
git clone -q --depth 2 "file://$history_repo" "$fixture/shallow-deep"
run_check "$fixture/shallow-deep"
if grep -q 'history boundary' "$fixture/out"; then
  cat "$fixture/out" >&2
  echo "a shallow clone holding the affirmation commit was reported as a boundary" >&2
  exit 1
fi

echo 'affirmation-check controls passed'
