#!/bin/bash

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
qualifier="$repository_root/Scripts/qualify-release-candidate.sh"
temporary_root=$(mktemp -d /private/tmp/spacetrace-rc-qualifier-contract.XXXXXX)

cleanup() {
    rm -rf -- "$temporary_root"
}
trap cleanup EXIT INT TERM HUP

expect_quarantine_rejection() {
    local label=$1
    local primary=$2
    local replacement=$3
    local output="$temporary_root/$label.txt"
    local status=0

    "$qualifier" --primary "$primary" --replacement "$replacement" \
        >"$output" 2>&1 || status=$?

    if [[ $status -ne 2 ]]; then
        printf 'error: %s returned %s instead of 2\n' "$label" "$status" >&2
        cat "$output" >&2
        exit 1
    fi
    if ! grep -Fq \
        'error: non-interactive qualification refuses quarantined app input' \
        "$output"; then
        printf 'error: %s did not report the quarantine boundary\n' "$label" >&2
        cat "$output" >&2
        exit 1
    fi
}

mkdir "$temporary_root/primary.app" "$temporary_root/replacement.app"
xattr -w com.apple.quarantine \
    '0081;66bd0000;SpaceTraceQualification;' \
    "$temporary_root/primary.app"
expect_quarantine_rejection \
    primary-quarantined \
    "$temporary_root/primary.app" \
    "$temporary_root/replacement.app"

xattr -d com.apple.quarantine "$temporary_root/primary.app"
xattr -w com.apple.quarantine \
    '0081;66bd0000;SpaceTraceQualification;' \
    "$temporary_root/replacement.app"
expect_quarantine_rejection \
    replacement-quarantined \
    "$temporary_root/primary.app" \
    "$temporary_root/replacement.app"

printf 'release candidate qualification contract: PASS\n'
