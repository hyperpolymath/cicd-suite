#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Log text is an observation, not a receipt that a scanner or prover ran.
set -euo pipefail

echo 'Inspecting available metric logs (advisory)...'
report_log() {
    local label=$1 log=$2 count rc
    if [[ ! -e "$log" ]]; then
        echo "$label: NOT ASSESSED ($log absent; scan execution and result unknown)."
        return
    fi
    if [[ ! -f "$log" || ! -r "$log" ]]; then
        echo "::warning::$label: NOT ASSESSED ($log is not a readable regular file)."
        return
    fi

    # grep returns 1 for a valid zero count. Do not append a second zero, and
    # do not turn an I/O or tool failure into a count.
    if count=$(grep -c -- ERROR "$log"); then
        :
    else
        rc=$?
        if [[ "$rc" -ne 1 ]]; then
            echo "::warning::$label: NOT ASSESSED (could not read $log; grep exited $rc)."
            return
        fi
    fi
    echo "$label ERROR-marker lines: $count"
}

report_log Pons pons.log
report_log 'Panic Attack' panic.log
echo 'Log counts do not establish scan execution, freshness, or success.'
echo 'Proof status: NOT ASSESSED (requires compiler/prover results; source keywords are not proof evidence).'
