#!/bin/zsh

set -euo pipefail

if (( $# != 3 )); then
    print -u2 "usage: $0 /absolute/path/to/SpaceTrace.app /absolute/path/to/diagnostics /absolute/path/to/report.json"
    exit 64
fi

app_path=$1
diagnostics_path=$2
report_path=$3

if [[ $diagnostics_path != /* || ! -d $diagnostics_path ]]; then
    print -u2 "error: diagnostics path must be an existing absolute directory"
    exit 64
fi
if [[ $report_path != /* ]]; then
    print -u2 "error: report path must be absolute"
    exit 64
fi

script_directory=${0:A:h}
repository_root=${script_directory:h}

"$script_directory/qualify-user-selected-directory.sh" "$app_path"

analyzer_arguments=(
    --input "$diagnostics_path"
    --output "$report_path"
)
if [[ -n ${SPACETRACE_SOAK_SMOKE_SECONDS:-} ]]; then
    analyzer_arguments+=(--smoke "$SPACETRACE_SOAK_SMOKE_SECONDS")
    print "warning: smoke policy is active; this is not 24-hour qualification"
fi

swift run \
    --package-path "$repository_root/Packages/SpaceTraceKit" \
    SpaceTraceSoakAnalyzer \
    "${analyzer_arguments[@]}"

print "background soak analysis: PASS"
print "report: $report_path"
