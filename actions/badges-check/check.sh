#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Advisory presence checks only. A README word is not accreditation evidence.
set -euo pipefail

echo 'Inspecting badge conventions (advisory)...'
readme=README.adoc
if [[ -f README.md ]]; then readme=README.md; fi
if [[ ! -f "$readme" ]]; then
    echo '::warning::No README found to check badges.'
    exit 0
fi

# Preserve the estate's existing recommendations. Missing accreditation must
# be investigated, never invented just to remove an annotation.
for badge in GLAMA Greenweb OpenSSF License; do
    if ! grep -qi -- "$badge" "$readme"; then
        echo "::warning::Missing $badge badge in $readme. Check standing and display."
    fi
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
    if ! grep -qi -- 'Idris Inside' "$readme"; then
        echo "::warning::Idris source detected but 'Idris Inside' badge is missing."
    fi
    if ! grep -qi -- RSR "$readme"; then
        echo '::warning::Missing RSR-compliant badge in Idris repository.'
    fi
else
    echo 'Idris badge advice is not applicable: no existing tracked Idris sources or packages.'
fi
echo 'Badge presence advice complete; accreditation standing was not assessed.'
