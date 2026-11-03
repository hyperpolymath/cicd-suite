#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Advisory presence checks only. A README word is not accreditation evidence.
set -euo pipefail

echo 'Inspecting badge conventions (advisory)...'
readme=README.adoc
if [[ -f README.md ]]; then readme=README.md; fi
if [[ ! -f "$readme" ]]; then
    echo '::warning::No README found to check badges; badge presence NOT ASSESSED.'
    exit 0
fi
if [[ ! -r "$readme" ]]; then
    echo "::warning::Badge presence NOT ASSESSED: $readme is not readable." >&2
    exit 0
fi

# A non-match is advice about missing wording; a failed read/tool is unknown.
# Read the whole file rather than grep -q, which can succeed after a match
# even when a read error also occurred.
advise_badge() {
    local pattern=$1 missing_message=$2 rc
    if grep -i -- "$pattern" "$readme" > /dev/null; then
        return
    else
        rc=$?
    fi
    if [[ "$rc" -eq 1 ]]; then
        printf '::warning::%s\n' "$missing_message"
    else
        printf '::warning::Badge presence NOT ASSESSED for %s: cannot inspect %s (grep exited %s).\n' \
            "$pattern" "$readme" "$rc" >&2
    fi
}

# Preserve the estate's existing recommendations. Missing accreditation must
# be investigated, never invented just to remove an annotation.
for badge in GLAMA Greenweb OpenSSF License; do
    advise_badge "$badge" "Missing $badge badge in $readme. Check standing and display."
done

# A generic src/ directory says nothing about language. Inspect existing,
# tracked Idris sources/packages, including nested paths and unusual filenames.
if ! source_list=$(mktemp); then
    echo '::warning::Idris badge applicability NOT ASSESSED: cannot create a source inventory.'
    exit 0
fi
trap 'rm -f "$source_list"' EXIT
if ! git ls-files -z -- '*.idr' '*.lidr' '*.ipkg' > "$source_list"; then
    echo '::warning::Idris badge applicability NOT ASSESSED: cannot inspect tracked sources.'
    exit 0
fi
has_idris=false
while IFS= read -r -d '' source; do
    if [[ -f "$source" ]]; then
        has_idris=true
        break
    fi
done < "$source_list"

if [[ "$has_idris" = true ]]; then
    advise_badge 'Idris Inside' "Idris source detected but 'Idris Inside' badge is missing."
    advise_badge RSR 'Missing RSR-compliant badge in Idris repository.'
else
    echo 'Idris badge advice is not applicable: no existing tracked Idris sources or packages.'
fi
echo 'Badge presence advice complete; accreditation standing was not assessed.'
