#!/bin/bash

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
checker="$repository_root/Scripts/check-pull-request-cla.sh"
scratch_root=$(mktemp -d "${TMPDIR:-/tmp}/spacetrace-cla-check.XXXXXX")
trap 'rm -rf "$scratch_root"' EXIT INT TERM HUP

if [[ ! -x $checker ]]; then
    printf 'RED: pull-request CLA checker is missing\n' >&2
    exit 1
fi

readonly checkbox='- [x] I have read and agree to the [SpaceTrace Contributor License Agreement](https://github.com/TREAFREE/SpaceTrace/blob/main/CONTRIBUTOR_LICENSE_AGREEMENT.md), version 1.0, SHA-256 `16990ce778b15efc0b60a51b54997a0fbb535cc3e4df85d97e3af2e80dc64bca`, and I have authority to submit every Contribution in this PR.'

write_event() {
    local destination=$1
    local body=$2
    jq -n --arg body "$body" '{pull_request:{body:$body}}' >"$destination"
}

expect_result() {
    local label=$1
    local expected_status=$2
    local expected_message=$3
    local event=$4
    local output="$scratch_root/$label.output"
    local status=0
    "$checker" "$event" >"$output" 2>&1 || status=$?
    [[ $status -eq $expected_status ]] || {
        printf 'FAIL: %s returned %s instead of %s\n' \
            "$label" "$status" "$expected_status" >&2
        exit 1
    }
    grep -Fxq "$expected_message" "$output" || {
        printf 'FAIL: %s emitted a noncanonical result\n' "$label" >&2
        exit 1
    }
    if grep -Fq "$scratch_root" "$output" \
        || grep -Fq 'untrusted-title' "$output"; then
        printf 'FAIL: %s disclosed event content or a local path\n' "$label" >&2
        exit 1
    fi
}

accepted="$scratch_root/accepted.json"
write_event "$accepted" $'untrusted-title\n\n'"$checkbox"
expect_result accepted 0 'pull-request CLA check: PASS' "$accepted"

uppercase="$scratch_root/uppercase.json"
write_event "$uppercase" "${checkbox/\[x\]/[X]}"
expect_result uppercase 0 'pull-request CLA check: PASS' "$uppercase"

unchecked="$scratch_root/unchecked.json"
write_event "$unchecked" "${checkbox/\[x\]/[ ]}"
expect_result unchecked 1 \
    'pull-request CLA check: FAIL (affirmative acceptance required)' "$unchecked"

wrong_link="$scratch_root/wrong-link.json"
write_event "$wrong_link" \
    "${checkbox/\/blob\/main\/CONTRIBUTOR_LICENSE_AGREEMENT.md/\/blob\/feature\/CONTRIBUTOR_LICENSE_AGREEMENT.md}"
expect_result wrong-link 1 \
    'pull-request CLA check: FAIL (affirmative acceptance required)' "$wrong_link"

missing_body="$scratch_root/missing-body.json"
printf '%s\n' '{"pull_request":{"body":null}}' >"$missing_body"
expect_result missing-body 1 \
    'pull-request CLA check: FAIL (affirmative acceptance required)' "$missing_body"

malformed="$scratch_root/malformed.json"
printf '%s\n' '{' >"$malformed"
expect_result malformed 2 \
    'pull-request CLA check: ERROR (event contract)' "$malformed"

event_link="$scratch_root/event-link.json"
ln -s "$accepted" "$event_link"
expect_result symlink 2 \
    'pull-request CLA check: ERROR (event contract)' "$event_link"

expect_result missing-argument 64 'usage: check-pull-request-cla.sh <event.json>' ""

printf 'pull-request CLA checker contract: PASS (8 cases)\n'
