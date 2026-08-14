#!/bin/zsh

set -euo pipefail

if (( $# != 5 )); then
    print -u2 "usage: $0 /absolute/path/to/SpaceTrace.app /absolute/path/to/manifest.json /absolute/path/to/diagnostics /absolute/path/to/report.json /absolute/path/to/preflight.json"
    exit 64
fi

app_path=$1
manifest_path=$2
diagnostics_path=$3
report_path=$4
preflight_path=$5

if [[ $diagnostics_path != /* || ! -d $diagnostics_path ]]; then
    print -u2 "error: diagnostics path must be an existing absolute directory"
    exit 64
fi
if [[ $report_path != /* ]]; then
    print -u2 "error: report path must be absolute"
    exit 64
fi
if [[ $manifest_path != /* || ! -f $manifest_path || -L $manifest_path ]]; then
    print -u2 "error: manifest must be an existing absolute regular file"
    exit 64
fi
if [[ $preflight_path != /* || -e $preflight_path || -L $preflight_path ]]; then
    print -u2 "error: preflight output must name a new absolute file"
    exit 64
fi

script_directory=${0:A:h}
repository_root=${script_directory:h}

preflight_arguments=(
    --app "$app_path"
    --manifest "$manifest_path"
    --distribution-mode adhoc-public-beta
    --accept-risk
    --output "$preflight_path"
)
if [[ -n ${SPACETRACE_SOAK_SMOKE_SECONDS:-} ]]; then
    preflight_arguments+=(--allow-newer-host-smoke)
fi
"$script_directory/qualify-user-selected-directory.sh" \
    "${preflight_arguments[@]}"

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

preflight_result=$(plutil -extract status raw -expect string -o - \
    "$preflight_path")
if [[ $preflight_result == passed ]]; then
    print "background soak analysis: PASS"
else
    print "background soak analysis: SMOKE"
fi
print "report: $report_path"
