#!/bin/zsh

set -euo pipefail

readonly trial_count=20
readonly required_passes=19
readonly minimum_free_kib=8388608
readonly maximum_log_bytes=8388608
readonly expected_test_identifier='SpaceTracePersistenceTests.ReconciliationKPIIntegrationTests/recoversAllocatedFiveGiBChangeAfterContinuityLoss()'

usage() {
    print -u2 'usage: qualify-apfs-reconciliation-matrix.sh --output <new-report-path>'
    exit 64
}

[[ $# -eq 2 && $1 == '--output' && -n $2 ]] || usage

script_directory=${0:A:h}
repository_root=${script_directory:h}
package_path="$repository_root/Packages/SpaceTraceKit"
output_path=$2
if [[ $output_path != /* ]]; then
    output_path="$repository_root/$output_path"
fi

[[ ! -e $output_path && ! -L $output_path ]] || {
    print -u2 'qualification report already exists; refusing to overwrite it'
    exit 64
}

for dependency in swift git stat df awk grep mktemp shasum sw_vers xcodebuild sysctl \
    uname paste date mkdir rm chmod mv ln basename find; do
    command -v "$dependency" >/dev/null 2>&1 || {
        print -u2 'qualification infrastructure is unavailable'
        exit 2
    }
done

git -C "$repository_root" diff --quiet --ignore-submodules -- \
    && git -C "$repository_root" diff --cached --quiet --ignore-submodules -- \
    || {
        print -u2 'qualification requires a clean tracked source tree'
        exit 65
    }
[[ -z $(git -C "$repository_root" ls-files --others --exclude-standard) ]] || {
    print -u2 'qualification requires a clean untracked source tree'
    exit 65
}

temporary_root=${TMPDIR:-/private/tmp}
df -T apfs "$temporary_root" >/dev/null 2>&1 || {
    print -u2 'qualification requires an APFS temporary volume'
    exit 69
}
filesystem_type='apfs'
available_kib=$(df -Pk "$temporary_root" | awk 'NR == 2 { print $4 }')
[[ $available_kib == <-> && $available_kib -ge $minimum_free_kib ]] || {
    print -u2 'qualification requires at least 8 GiB of available temporary capacity'
    exit 69
}

output_directory=${output_path:h}
mkdir -p "$output_directory"
temporary_report=$(mktemp "$output_directory/.reconciliation-matrix-report.XXXXXX")
temporary_log=''
fixture_parent=''
cleanup() {
    [[ -z $temporary_log ]] || rm -f "$temporary_log"
    [[ -z $fixture_parent ]] || rm -rf -- "$fixture_parent"
    rm -f "$temporary_report"
}
trap cleanup EXIT INT TERM

module_cache="$repository_root/build/ModuleCache"
mkdir -p "$module_cache"
preflight_log=$(mktemp "${temporary_root%/}/spacetrace-reconciliation-preflight.XXXXXX")
temporary_log=$preflight_log
set +e
(
    ulimit -f $((maximum_log_bytes / 512))
    CLANG_MODULE_CACHE_PATH="$module_cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
        swift test --package-path "$package_path" list
) >"$preflight_log" 2>&1
preflight_status=$?
set -e
preflight_size=$(stat -f '%z' "$preflight_log")
if [[ $preflight_status -ne 0 || $preflight_size -ge $maximum_log_bytes ]] \
    || ! grep -Fxq "$expected_test_identifier" "$preflight_log"; then
    print -u2 'qualification test discovery failed'
    exit 2
fi
rm -f "$preflight_log"
temporary_log=''

source_commit=$(git -C "$repository_root" rev-parse HEAD)
host_os=$(sw_vers -productVersion)
architecture=$(uname -m)
processor=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || print 'unknown')
memory_bytes=$(sysctl -n hw.memsize 2>/dev/null || print 'unknown')
xcode_version=$(xcodebuild -version | paste -sd ' ' -)
thermal_state='unavailable'
if command -v pmset >/dev/null 2>&1; then
    thermal_output=$(pmset -g therm 2>/dev/null || true)
    if [[ $thermal_output == *'No thermal warning level has been recorded'* ]]; then
        thermal_state='no-recorded-warning'
    else
        thermal_state='warning-or-unknown'
    fi
fi

{
    print 'format=SpaceTraceReconciliationKPIMatrixV1'
    print "sourceCommit=$source_commit"
    print "hostOS=$host_os"
    print "architecture=$architecture"
    print "processor=$processor"
    print "memoryBytes=$memory_bytes"
    print "xcode=$xcode_version"
    print "filesystem=$filesystem_type"
    print "thermalStateBefore=$thermal_state"
    print "trials=$trial_count"
    print "requiredPasses=$required_passes"
} >"$temporary_report"

passed=0
failed=0
fixture_parent=$(mktemp -d "${temporary_root%/}/spacetrace-reconciliation-matrix.XXXXXX")
for trial in {1..20}; do
    available_kib=$(df -Pk "$temporary_root" | awk 'NR == 2 { print $4 }')
    [[ $available_kib == <-> && $available_kib -ge $minimum_free_kib ]] || {
        print -u2 'temporary capacity fell below the 8 GiB qualification floor'
        exit 69
    }

    temporary_log=$(mktemp "${temporary_root%/}/spacetrace-reconciliation-trial.XXXXXX")
    started_seconds=$(date +%s)
    set +e
    (
        ulimit -f $((maximum_log_bytes / 512))
        SPACETRACE_RUN_APFS_RECONCILIATION_TESTS=1 \
        SPACETRACE_RECONCILIATION_FIXTURE_PARENT="$fixture_parent" \
        CLANG_MODULE_CACHE_PATH="$module_cache" \
        SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
            swift test --package-path "$package_path" --skip-build \
                --filter ReconciliationKPIIntegrationTests
    ) >"$temporary_log" 2>&1
    trial_status=$?
    set -e
    duration_seconds=$(( $(date +%s) - started_seconds ))
    log_size=$(stat -f '%z' "$temporary_log")
    [[ $log_size -lt $maximum_log_bytes ]] || {
        print -u2 'qualification trial output exceeded its bounded diagnostic budget'
        exit 2
    }
    rm -f "$temporary_log"
    temporary_log=''
    [[ -z $(find "$fixture_parent" -mindepth 1 -maxdepth 1 -print -quit) ]] || {
        print -u2 'qualification fixture cleanup was incomplete'
        exit 2
    }

    trial_label=$(printf '%02d' "$trial")
    if [[ $trial_status -eq 0 ]]; then
        passed=$((passed + 1))
        print "trial${trial_label}=passed durationSeconds=$duration_seconds" \
            >>"$temporary_report"
    else
        failed=$((failed + 1))
        print "trial${trial_label}=failed durationSeconds=$duration_seconds" \
            >>"$temporary_report"
    fi
done
rm -rf -- "$fixture_parent"
fixture_parent=''

thermal_state_after='unavailable'
if command -v pmset >/dev/null 2>&1; then
    thermal_output=$(pmset -g therm 2>/dev/null || true)
    if [[ $thermal_output == *'No thermal warning level has been recorded'* ]]; then
        thermal_state_after='no-recorded-warning'
    else
        thermal_state_after='warning-or-unknown'
    fi
fi

{
    print "passed=$passed"
    print "failed=$failed"
    print "thermalStateAfter=$thermal_state_after"
} >>"$temporary_report"

result_status=1
if [[ $passed -ge $required_passes ]]; then
    print 'result=passed' >>"$temporary_report"
    result_status=0
else
    print 'result=failed' >>"$temporary_report"
fi

chmod 600 "$temporary_report"
ln "$temporary_report" "$output_path" || {
    print -u2 'qualification report destination changed during publication'
    exit 64
}
rm -f "$temporary_report"
trap - EXIT INT TERM
report_digest=$(shasum -a 256 "$output_path" | awk '{ print $1 }')
print "reconciliation_matrix_passed=$passed"
print "reconciliation_matrix_failed=$failed"
print "qualification_report=$(basename "$output_path")"
print "qualification_report_sha256=$report_digest"
exit $result_status
