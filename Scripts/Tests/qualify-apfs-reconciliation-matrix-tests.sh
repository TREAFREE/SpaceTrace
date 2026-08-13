#!/bin/bash

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
production_script="$repository_root/Scripts/qualify-apfs-reconciliation-matrix.sh"
scratch_root=$(mktemp -d "${TMPDIR:-/tmp}/spacetrace-reconciliation-matrix-contract.XXXXXX")
trap 'rm -rf "$scratch_root"' EXIT

passed_cases=0
failed_cases=0

fail_case() {
    printf 'FAIL: %s\n' "$1" >&2
    failed_cases=$((failed_cases + 1))
}

pass_case() {
    passed_cases=$((passed_cases + 1))
}

create_fixture_repository() {
    local fixture_root=$1
    mkdir -p "$fixture_root/Scripts" "$fixture_root/Packages/SpaceTraceKit" "$fixture_root/fake-bin"
    cp "$production_script" "$fixture_root/Scripts/qualify-apfs-reconciliation-matrix.sh"
    chmod +x "$fixture_root/Scripts/qualify-apfs-reconciliation-matrix.sh"

    cat > "$fixture_root/README.md" <<'EOF'
Synthetic qualification fixture.
EOF
    cat > "$fixture_root/fake-bin/swift" <<'EOF'
#!/bin/bash
set -euo pipefail
count_file=${SPACETRACE_FAKE_SWIFT_COUNT_FILE:?}
failure_plan=${SPACETRACE_FAKE_SWIFT_FAILURE_PLAN:-}
if [[ " $* " == *" list "* ]]; then
    printf '%s\n' \
        'SpaceTracePersistenceTests.ReconciliationKPIIntegrationTests/recoversAllocatedFiveGiBChangeAfterContinuityLoss()'
    exit 0
fi
[[ -n ${SPACETRACE_RECONCILIATION_FIXTURE_PARENT:-} \
    && -d $SPACETRACE_RECONCILIATION_FIXTURE_PARENT ]] || exit 72
count=0
if [[ -f "$count_file" ]]; then
    count=$(<"$count_file")
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
case ",$failure_plan," in
    *",$count,"*) exit 1 ;;
esac
exit 0
EOF
    chmod +x "$fixture_root/fake-bin/swift"

    git -C "$fixture_root" init -q
    git -C "$fixture_root" config user.name "SpaceTrace Tests"
    git -C "$fixture_root" config user.email "tests@example.invalid"
    git -C "$fixture_root" add README.md Scripts/qualify-apfs-reconciliation-matrix.sh fake-bin/swift
    git -C "$fixture_root" commit -q -m "fixture"
}

run_case() {
    local name=$1
    local failure_plan=$2
    local expected_status=$3
    local expected_passes=$4
    local expected_failures=$5
    local fixture_root="$scratch_root/$name-repository"
    local report="$fixture_root/report.txt"
    local count_file="$fixture_root/swift-count.txt"
    local output="$scratch_root/$name-command-output.txt"

    create_fixture_repository "$fixture_root"
    set +e
    PATH="$fixture_root/fake-bin:$PATH" \
        SPACETRACE_FAKE_SWIFT_COUNT_FILE="$count_file" \
        SPACETRACE_FAKE_SWIFT_FAILURE_PLAN="$failure_plan" \
        "$fixture_root/Scripts/qualify-apfs-reconciliation-matrix.sh" \
            --output "$report" >"$output" 2>&1
    local actual_status=$?
    set -e

    if [[ $actual_status -ne $expected_status ]]; then
        fail_case "$name returned $actual_status, expected $expected_status"
        return
    fi
    if [[ ! -f "$count_file" || $(<"$count_file") -ne 20 ]]; then
        fail_case "$name did not execute exactly 20 independent trials"
        return
    fi
    if [[ ! -f "$report" ]]; then
        fail_case "$name did not create a report"
        return
    fi
    if ! grep -Fxq "trials=20" "$report" \
        || ! grep -Fxq "requiredPasses=19" "$report" \
        || ! grep -Fxq "passed=$expected_passes" "$report" \
        || ! grep -Fxq "failed=$expected_failures" "$report"; then
        fail_case "$name report counters are not canonical"
        return
    fi
    if [[ $(grep -Ec '^trial[0-9]{2}=(passed|failed) durationSeconds=[0-9]+$' "$report") -ne 20 ]]; then
        fail_case "$name report does not contain 20 bounded trial rows"
        return
    fi
    if grep -q '/' "$report"; then
        fail_case "$name report contains a raw local path"
        return
    fi
    if [[ $expected_status -eq 0 ]]; then
        grep -Fxq "result=passed" "$report" || {
            fail_case "$name did not record a passing result"
            return
        }
    else
        grep -Fxq "result=failed" "$report" || {
            fail_case "$name did not record a failing result"
            return
        }
    fi
    pass_case
}

run_case "all-pass" "" 0 20 0
run_case "one-product-failure" "7" 0 19 1
run_case "two-product-failures" "3,17" 1 18 2

existing_root="$scratch_root/existing-output"
create_fixture_repository "$existing_root"
printf 'do not replace\n' > "$existing_root/report.txt"
set +e
PATH="$existing_root/fake-bin:$PATH" \
    SPACETRACE_FAKE_SWIFT_COUNT_FILE="$existing_root/swift-count.txt" \
    "$existing_root/Scripts/qualify-apfs-reconciliation-matrix.sh" \
        --output "$existing_root/report.txt" >"$existing_root/output.txt" 2>&1
existing_status=$?
set -e
if [[ $existing_status -ne 64 ]]; then
    fail_case "existing output was not rejected with usage status 64"
elif [[ -e "$existing_root/swift-count.txt" ]]; then
    fail_case "existing output rejection executed a trial"
elif [[ $(<"$existing_root/report.txt") != "do not replace" ]]; then
    fail_case "existing output was overwritten"
else
    pass_case
fi

printf 'APFS reconciliation matrix contract: %d passed, %d failed\n' \
    "$passed_cases" "$failed_cases"
(( failed_cases == 0 ))
