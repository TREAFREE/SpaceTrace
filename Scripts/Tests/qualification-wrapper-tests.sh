#!/bin/bash

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scratch_root=$(mktemp -d "${TMPDIR:-/tmp}/spacetrace-qualification-wrapper.XXXXXX")
trap 'rm -rf "$scratch_root"' EXIT INT TERM HUP

fixture_root="$scratch_root/fixture"
script_directory="$fixture_root/Scripts"
tool_directory="$scratch_root/tools"
app="$scratch_root/SpaceTrace.app"
manifest="$scratch_root/SpaceTrace.manifest.json"
diagnostics="$scratch_root/diagnostics"
evidence="$scratch_root/evidence"
mkdir -p "$script_directory" "$tool_directory" "$app" "$diagnostics" "$evidence"
cp "$repository_root/Scripts/qualify-background-soak.sh" "$script_directory/"
cp "$repository_root/Scripts/run-current-host-soak.sh" "$script_directory/"
chmod 755 "$script_directory/qualify-background-soak.sh" \
    "$script_directory/run-current-host-soak.sh"
printf '%s\n' '{"schemaVersion":1}' >"$manifest"

cat >"$script_directory/qualify-user-selected-directory.sh" <<'QUALIFIER'
#!/bin/zsh
set -euo pipefail
output=""
while (( $# > 0 )); do
    case "$1" in
        --output)
            output=$2
            print -r -- "$1" "$2" >>"$SPACETRACE_TEST_QUALIFIER_LOG"
            shift 2
            ;;
        *)
            print -r -- "$1" >>"$SPACETRACE_TEST_QUALIFIER_LOG"
            shift
            ;;
    esac
done
[[ -n $output ]]
plutil -create xml1 "$output"
plutil -insert status -string "${SPACETRACE_TEST_PREFLIGHT_STATUS:-passed}" "$output"
QUALIFIER
chmod 755 "$script_directory/qualify-user-selected-directory.sh"

cat >"$tool_directory/swift" <<'SWIFT'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$@" >>"$SPACETRACE_TEST_SWIFT_LOG"
output=""
while (($# > 0)); do
    if [[ $1 == --output && $# -ge 2 ]]; then
        output=$2
        shift 2
    else
        shift
    fi
done
[[ -n $output ]]
printf '%s\n' '{"schemaVersion":1}' >"$output"
SWIFT
chmod 755 "$tool_directory/swift"

expect_status() {
    local expected=$1
    shift
    local actual=0
    "$@" >"$scratch_root/failure.stdout" 2>"$scratch_root/failure.stderr" \
        || actual=$?
    if [[ $actual -ne $expected ]]; then
        printf 'FAIL: wrapper returned %s instead of %s\n' "$actual" "$expected" >&2
        exit 1
    fi
}

qualifier_log="$scratch_root/qualifier.log"
swift_log="$scratch_root/swift.log"
report="$scratch_root/report.json"
preflight="$scratch_root/preflight.json"
PATH="$tool_directory:/usr/bin:/bin:/usr/sbin:/sbin" \
SPACETRACE_TEST_QUALIFIER_LOG="$qualifier_log" \
SPACETRACE_TEST_SWIFT_LOG="$swift_log" \
    "$script_directory/qualify-background-soak.sh" \
    "$app" "$manifest" "$diagnostics" "$report" "$preflight" \
    >"$scratch_root/pass.stdout" 2>"$scratch_root/pass.stderr"
grep -Fxq 'background soak analysis: PASS' "$scratch_root/pass.stdout"
[[ ! -s $scratch_root/pass.stderr ]]
[[ -f $report && -f $preflight ]]
grep -Fxq -- '--distribution-mode' "$qualifier_log"
grep -Fxq -- 'adhoc-public-beta' "$qualifier_log"
grep -Fxq -- '--accept-risk' "$qualifier_log"
if grep -Fxq -- '--allow-newer-host-smoke' "$qualifier_log"; then
    printf 'FAIL: strict wrapper unexpectedly enabled newer-host smoke\n' >&2
    exit 1
fi
grep -Fxq -- 'SpaceTraceSoakAnalyzer' "$swift_log"

smoke_report="$scratch_root/smoke-report.json"
smoke_preflight="$scratch_root/smoke-preflight.json"
: >"$qualifier_log"
PATH="$tool_directory:/usr/bin:/bin:/usr/sbin:/sbin" \
SPACETRACE_TEST_QUALIFIER_LOG="$qualifier_log" \
SPACETRACE_TEST_SWIFT_LOG="$swift_log" \
SPACETRACE_TEST_PREFLIGHT_STATUS=smoke \
SPACETRACE_SOAK_SMOKE_SECONDS=60 \
    "$script_directory/qualify-background-soak.sh" \
    "$app" "$manifest" "$diagnostics" "$smoke_report" "$smoke_preflight" \
    >"$scratch_root/smoke.stdout" 2>"$scratch_root/smoke.stderr"
grep -Fxq 'background soak analysis: SMOKE' "$scratch_root/smoke.stdout"
grep -Fxq -- '--allow-newer-host-smoke' "$qualifier_log"

expect_status 64 "$script_directory/qualify-background-soak.sh" \
    "$app" "$diagnostics" "$scratch_root/old-report.json"
manifest_link="$scratch_root/manifest-link.json"
ln -s "$manifest" "$manifest_link"
expect_status 64 "$script_directory/qualify-background-soak.sh" \
    "$app" "$manifest_link" "$diagnostics" \
    "$scratch_root/link-report.json" "$scratch_root/link-preflight.json"

expect_status 64 "$script_directory/run-current-host-soak.sh" start \
    "$app" "$evidence" 60
expect_status 64 "$script_directory/run-current-host-soak.sh" start \
    "$app" "$manifest_link" "$evidence" 60
expect_status 64 "$script_directory/run-current-host-soak.sh" start \
    "$app" "$manifest" "$evidence" 59

printf 'qualification wrapper contract: PASS\n'
