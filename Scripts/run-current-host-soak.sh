#!/bin/zsh

set -u

worker_cleanup_completed=0
worker_cleanup_app_pid=""
worker_cleanup_bundle_identifier=""
worker_cleanup_evidence_directory=""
worker_cleanup_failure_reason="unexpected_worker_exit"

usage() {
    print -u2 "usage:"
    print -u2 "  $0 start /absolute/path/to/SpaceTrace.app /absolute/path/to/evidence <duration-seconds>"
    print -u2 "  $0 status /absolute/path/to/evidence"
    print -u2 "  $0 finalize /absolute/path/to/evidence"
    exit 64
}

if (( $# < 1 )); then
    usage
fi

command_name=$1
shift
script_directory=${0:A:h}
script_path=${0:A}
repository_root=${script_directory:h}

require_absolute_directory() {
    local path=$1
    if [[ $path != /* || ! -d $path ]]; then
        print -u2 "error: expected an existing absolute directory: $path"
        exit 64
    fi
}

launchd_is_running() {
    local label=$1
    local launchd_state
    launchd_state=$(launchctl print \
        "gui/$(id -u)/$label" 2>/dev/null)
    [[ $launchd_state == *"state = running"* ]]
}

status_command() {
    if (( $# != 1 )); then
        usage
    fi
    local evidence_directory=$1
    require_absolute_directory "$evidence_directory"

    local state_file="$evidence_directory/run-status.txt"
    local supervisor_label_file="$evidence_directory/supervisor.label"
    local app_pid_file="$evidence_directory/app.pid"

    local recorded_status="NOT_STARTED"
    [[ -f $state_file ]] && recorded_status=$(<"$state_file")
    local supervisor_running=0
    local app_running=0
    if [[ -f $supervisor_label_file ]]; then
        local supervisor_label
        supervisor_label=$(<"$supervisor_label_file")
        if launchd_is_running "$supervisor_label"; then
            supervisor_running=1
        fi
    fi
    if [[ -f $app_pid_file ]]; then
        local app_pid
        app_pid=$(<"$app_pid_file")
        if kill -0 "$app_pid" 2>/dev/null; then
            app_running=1
        fi
    fi
    if [[ $recorded_status == "RUNNING" &&
          $supervisor_running == 0 &&
          $app_running == 0 ]]; then
        print "status: FAILED (recorded RUNNING; supervisor and app absent)"
    else
        print "status: $recorded_status"
    fi
    if [[ -f $supervisor_label_file ]]; then
        supervisor_label=$(<"$supervisor_label_file")
        if (( supervisor_running == 1 )); then
            print "supervisor: running ($supervisor_label)"
        else
            print "supervisor: not running ($supervisor_label)"
        fi
    fi
    if [[ -f $app_pid_file ]]; then
        app_pid=$(<"$app_pid_file")
        if (( app_running == 1 )); then
            print "app: running (pid $app_pid)"
        else
            print "app: not running (last pid $app_pid)"
        fi
    fi
    if [[ -f "$evidence_directory/run-window.txt" ]]; then
        sed -n '1,20p' "$evidence_directory/run-window.txt"
    fi
    if [[ -d "$evidence_directory/instruments" ]]; then
        local -a traces
        traces=("$evidence_directory"/instruments/*.trace(N))
        if (( ${#traces} > 0 )); then
            print "instrument traces:"
            du -sh "${traces[@]}" 2>/dev/null
        fi
    fi
    if [[ -f "$evidence_directory/supervisor.log" ]]; then
        print "recent supervisor output:"
        tail -20 "$evidence_directory/supervisor.log"
    fi
}

write_metadata() {
    local app_path=$1
    local evidence_directory=$2
    local duration_seconds=$3
    local app_binary="$app_path/Contents/MacOS/SpaceTrace"
    local info_plist="$app_path/Contents/Info.plist"
    local bundle_identifier
    bundle_identifier=$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleIdentifier' "$info_plist")
    local offsets_text
    offsets_text=${SPACETRACE_SOAK_CAPTURE_OFFSETS_SECONDS:-0,21600,43200,64800,86400}
    local capture_duration
    capture_duration=${SPACETRACE_SOAK_INSTRUMENT_DURATION:-5m}

    {
        print "host_product=$(sw_vers -productName)"
        print "host_version=$(sw_vers -productVersion)"
        print "host_build=$(sw_vers -buildVersion)"
        print "host_architecture=$(uname -m)"
        print "git_commit=$(git -C "$repository_root" rev-parse HEAD)"
        print "bundle_identifier=$bundle_identifier"
        print "minimum_system=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info_plist")"
        print "binary_sha256=$(shasum -a 256 "$app_binary" | awk '{print $1}')"
        print "xcode_version=$(xcodebuild -version | tr '\n' ' ')"
        print "instruments_template=Activity Monitor"
        print "instruments_capture_offsets_seconds=$offsets_text"
        print "instruments_capture_duration=$capture_duration"
        print "direct_power_template=unsupported_on_macos"
        print "powermetrics=requires_interactive_superuser"
        print "duration_seconds=$duration_seconds"
    } >"$evidence_directory/run-metadata.txt"
    chmod 600 "$evidence_directory/run-metadata.txt"
}

write_energy_capability_evidence() {
    local evidence_directory=$1
    local capability_file="$evidence_directory/energy-capability.txt"

    {
        print "This file records profiler availability; it is not an energy result."
        print
        print "== Installed xctrace templates =="
        xcrun xctrace list templates 2>&1 |
            rg 'Activity Monitor|Energy Log|Power Profiler' || true
        print
        print "== Power Profiler macOS support probe =="
        local probe_directory="$evidence_directory/power-profiler-support-probe.trace"
        xcrun xctrace record \
            --template 'Power Profiler' \
            --time-limit 1s \
            --no-prompt \
            --all-processes \
            --output "$probe_directory" 2>&1
        print "power_profiler_probe_exit_status=$?"
        print
        print "== powermetrics privilege probe =="
        /usr/bin/powermetrics \
            --show-process-energy \
            --sample-rate 100 \
            --sample-count 1 \
            --format plist \
            --output-file /dev/null 2>&1
        print "powermetrics_probe_exit_status=$?"
        print
        print "Interpretation: Activity Monitor is process-resource evidence. A rejected"
        print "Power Profiler probe or unprivileged powermetrics probe remains an explicit"
        print "direct-power evidence gap and must not be reported as watt/joule evidence."
    } >"$capability_file"
    chmod 600 "$capability_file"
}

start_command() {
    if (( $# != 3 )); then
        usage
    fi
    local source_app_path=$1
    local evidence_directory=$2
    local duration_seconds=$3

    require_absolute_directory "$source_app_path"
    require_absolute_directory "$evidence_directory"
    if [[ $source_app_path != *.app ]]; then
        print -u2 "error: app path must end in .app"
        exit 64
    fi
    if [[ $duration_seconds != <-> || $duration_seconds -lt 60 ]]; then
        print -u2 "error: duration must be at least 60 seconds"
        exit 64
    fi
    if [[ -e "$evidence_directory/supervisor.label" ||
          -e "$evidence_directory/run-status.txt" ]]; then
        print -u2 "error: evidence directory already contains run state"
        exit 2
    fi

    mkdir -m 700 -p \
        "$evidence_directory/instruments" \
        "$evidence_directory/reports" \
        "$evidence_directory/runtime"
    chmod 700 "$evidence_directory" "$evidence_directory/instruments" \
        "$evidence_directory/reports" "$evidence_directory/runtime"

    SPACETRACE_ALLOW_NEWER_HOST_SMOKE=1 \
    SPACETRACE_ALLOW_ADHOC_SMOKE=1 \
        "$script_directory/qualify-user-selected-directory.sh" \
        "$source_app_path" \
        >"$evidence_directory/signature-preflight.txt" 2>&1
    local preflight_status=$?
    chmod 600 "$evidence_directory/signature-preflight.txt"
    if (( preflight_status != 0 )); then
        print -u2 "error: signed sandbox preflight failed"
        sed -n '1,120p' "$evidence_directory/signature-preflight.txt"
        exit "$preflight_status"
    fi

    swift build \
        --package-path "$repository_root/Packages/SpaceTraceKit" \
        -c release \
        --product SpaceTraceSoakAnalyzer \
        >"$evidence_directory/analyzer-build.log" 2>&1
    local analyzer_build_status=$?
    chmod 600 "$evidence_directory/analyzer-build.log"
    if (( analyzer_build_status != 0 )); then
        print -u2 "error: qualification analyzer build failed"
        exit "$analyzer_build_status"
    fi

    local runtime_directory="$evidence_directory/runtime"
    local runtime_app="$runtime_directory/SpaceTrace.app"
    ditto "$source_app_path" "$runtime_app"
    cp "$script_path" "$runtime_directory/run-current-host-soak.sh"
    cp \
        "$repository_root/Packages/SpaceTraceKit/.build/release/SpaceTraceSoakAnalyzer" \
        "$runtime_directory/SpaceTraceSoakAnalyzer"
    chmod 700 "$runtime_directory/run-current-host-soak.sh" \
        "$runtime_directory/SpaceTraceSoakAnalyzer"
    codesign --verify --deep --strict "$runtime_app" \
        >>"$evidence_directory/signature-preflight.txt" 2>&1
    local runtime_signature_status=$?
    if (( runtime_signature_status != 0 )); then
        print -u2 "error: copied runtime app failed signature verification"
        exit "$runtime_signature_status"
    fi

    write_metadata "$runtime_app" "$evidence_directory" "$duration_seconds"
    write_energy_capability_evidence "$evidence_directory"

    local supervisor_label
    supervisor_label="com.treafree.spacetrace.soak.$(date +%s).$$"
    local instrument_duration
    instrument_duration=${SPACETRACE_SOAK_INSTRUMENT_DURATION:-5m}
    local capture_offsets
    capture_offsets=${SPACETRACE_SOAK_CAPTURE_OFFSETS_SECONDS:-0,21600,43200,64800,86400}
    local analyzer_smoke
    analyzer_smoke=${SPACETRACE_SOAK_ANALYZER_SMOKE_SECONDS:-}
    : >"$evidence_directory/supervisor.log"
    chmod 600 "$evidence_directory/supervisor.log"
    local supervisor_plist="$runtime_directory/supervisor.plist"
    plutil -create xml1 "$supervisor_plist"
    plutil -insert Label -string "$supervisor_label" "$supervisor_plist"
    plutil -insert ProgramArguments -array "$supervisor_plist"
    plutil -insert ProgramArguments.0 \
        -string "$runtime_directory/run-current-host-soak.sh" \
        "$supervisor_plist"
    plutil -insert ProgramArguments.1 -string worker "$supervisor_plist"
    plutil -insert ProgramArguments.2 \
        -string "$runtime_app" "$supervisor_plist"
    plutil -insert ProgramArguments.3 \
        -string "$evidence_directory" "$supervisor_plist"
    plutil -insert ProgramArguments.4 \
        -string "$duration_seconds" "$supervisor_plist"
    plutil -insert EnvironmentVariables -dictionary "$supervisor_plist"
    plutil -insert EnvironmentVariables.SPACETRACE_SOAK_INSTRUMENT_DURATION \
        -string "$instrument_duration" "$supervisor_plist"
    plutil -insert EnvironmentVariables.SPACETRACE_SOAK_CAPTURE_OFFSETS_SECONDS \
        -string "$capture_offsets" "$supervisor_plist"
    plutil -insert EnvironmentVariables.SPACETRACE_SOAK_ANALYZER_SMOKE_SECONDS \
        -string "$analyzer_smoke" "$supervisor_plist"
    plutil -insert RunAtLoad -bool true "$supervisor_plist"
    plutil -insert KeepAlive -bool false "$supervisor_plist"
    plutil -insert ProcessType -string Background "$supervisor_plist"
    plutil -insert StandardOutPath \
        -string "$evidence_directory/supervisor.log" "$supervisor_plist"
    plutil -insert StandardErrorPath \
        -string "$evidence_directory/supervisor.log" "$supervisor_plist"
    chmod 600 "$supervisor_plist"
    launchctl bootstrap "gui/$(id -u)" "$supervisor_plist"
    local launch_status=$?
    if (( launch_status != 0 )); then
        print -u2 "error: launchd rejected the soak supervisor"
        exit "$launch_status"
    fi
    print -r -- "$supervisor_label" \
        >"$evidence_directory/supervisor.label"
    chmod 600 "$evidence_directory/supervisor.label"
    print "started current-host soak supervisor ($supervisor_label)"
    print "evidence: $evidence_directory"
}

worker_command() {
    if (( $# != 3 )); then
        usage
    fi
    local app_path=$1
    local evidence_directory=$2
    local duration_seconds=$3
    local app_binary="$app_path/Contents/MacOS/SpaceTrace"
    local info_plist="$app_path/Contents/Info.plist"
    local bundle_identifier
    bundle_identifier=$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleIdentifier' "$info_plist")
    local capture_duration=${SPACETRACE_SOAK_INSTRUMENT_DURATION:-5m}
    local offsets_text=${SPACETRACE_SOAK_CAPTURE_OFFSETS_SECONDS:-0,21600,43200,64800,86400}
    local -a capture_offsets
    capture_offsets=(${(s:,:)offsets_text})
    local app_pid=""
    local capture_failures=0
    worker_cleanup_completed=0
    worker_cleanup_app_pid=""
    worker_cleanup_bundle_identifier=$bundle_identifier
    worker_cleanup_evidence_directory=$evidence_directory
    worker_cleanup_failure_reason="unexpected_worker_exit"

    remove_launchd_job() {
        trap - EXIT INT TERM HUP
        if [[ -n ${XPC_SERVICE_NAME:-} ]]; then
            launchctl bootout \
                "gui/$(id -u)/$XPC_SERVICE_NAME" >/dev/null 2>&1 ||
                launchctl remove "$XPC_SERVICE_NAME" >/dev/null 2>&1
        fi
    }

    stop_app_after_failure() {
        if [[ -n $worker_cleanup_app_pid ]] &&
            kill -0 "$worker_cleanup_app_pid" 2>/dev/null
        then
            osascript -e \
                "tell application id \"$worker_cleanup_bundle_identifier\" to quit" \
                >/dev/null 2>&1
            sleep 5
            if kill -0 "$worker_cleanup_app_pid" 2>/dev/null; then
                kill -TERM "$worker_cleanup_app_pid" 2>/dev/null
            fi
        fi
    }

    cleanup() {
        if (( worker_cleanup_completed == 0 )); then
            print "FAILED" \
                >"$worker_cleanup_evidence_directory/run-status.txt"
            chmod 600 \
                "$worker_cleanup_evidence_directory/run-status.txt"
            {
                print "failure_reason=$worker_cleanup_failure_reason"
                print "failed_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
            } >"$worker_cleanup_evidence_directory/failure-summary.txt"
            chmod 600 \
                "$worker_cleanup_evidence_directory/failure-summary.txt"
            stop_app_after_failure
        fi
        remove_launchd_job
    }
    trap cleanup EXIT INT TERM HUP

    local start_epoch
    start_epoch=$(date +%s)
    local end_epoch=$(( start_epoch + duration_seconds ))
    {
        print "started_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        print "expected_end_utc=$(date -r "$end_epoch" -u '+%Y-%m-%dT%H:%M:%SZ')"
        print "duration_seconds=$duration_seconds"
        print "capture_offsets_seconds=$offsets_text"
        print "capture_duration=$capture_duration"
    } >"$evidence_directory/run-window.txt"
    chmod 600 "$evidence_directory/run-window.txt"
    print "RUNNING" >"$evidence_directory/run-status.txt"
    chmod 600 "$evidence_directory/run-status.txt"

    launchctl setenv SPACETRACE_BACKGROUND_SOAK_DIAGNOSTICS 1
    open -n "$app_path"
    local open_status=$?
    launchctl unsetenv SPACETRACE_BACKGROUND_SOAK_DIAGNOSTICS
    if (( open_status != 0 )); then
        worker_cleanup_failure_reason="launch_services_rejected_app"
        print -u2 "error: LaunchServices rejected SpaceTrace"
        exit 1
    fi
    local startup_attempt
    for startup_attempt in {1..30}; do
        app_pid=$(pgrep -f "$app_binary" | head -1)
        if [[ -n $app_pid ]] && kill -0 "$app_pid" 2>/dev/null; then
            break
        fi
        app_pid=""
        sleep 1
    done
    if [[ -z $app_pid ]]; then
        worker_cleanup_failure_reason="app_did_not_start"
        print -u2 "error: SpaceTrace did not become a running application"
        exit 1
    fi
    worker_cleanup_app_pid=$app_pid
    print -r -- "$app_pid" >"$evidence_directory/app.pid"
    chmod 600 "$evidence_directory/app.pid"

    wait_until() {
        local target_epoch=$1
        local current_epoch
        local remaining
        while true; do
            if ! kill -0 "$app_pid" 2>/dev/null; then
                worker_cleanup_failure_reason="app_exited_before_qualification_end"
                print -u2 "error: SpaceTrace exited before qualification ended"
                return 1
            fi
            current_epoch=$(date +%s)
            if (( current_epoch >= target_epoch )); then
                return 0
            fi
            remaining=$(( target_epoch - current_epoch ))
            if (( remaining > 30 )); then
                sleep 30
            else
                sleep "$remaining"
            fi
        done
    }

    capture_instruments() {
        local index=$1
        local offset=$2
        local prefix
        prefix=$(printf 'activity-monitor-%02d-offset-%06d' "$index" "$offset")
        local trace="$evidence_directory/instruments/$prefix.trace"
        local log="$evidence_directory/instruments/$prefix.log"
        print "starting Instruments slice $index at offset $offset"
        xcrun xctrace record \
            --template 'Activity Monitor' \
            --time-limit "$capture_duration" \
            --no-prompt \
            --output "$trace" \
            --attach "$app_pid" >"$log" 2>&1
        local record_status=$?
        chmod 600 "$log"
        if (( record_status != 0 )); then
            print -u2 "warning: Instruments slice $index failed"
            capture_failures=$(( capture_failures + 1 ))
            return
        fi
        local export_failures=0
        xcrun xctrace export --input "$trace" --toc \
            --output "$evidence_directory/instruments/$prefix-toc.xml" \
            >>"$log" 2>&1
        if (( $? != 0 )); then
            export_failures=$(( export_failures + 1 ))
        fi
        xcrun xctrace export --input "$trace" \
            --xpath '/trace-toc/run[@number="1"]/data/table[@schema="activity-monitor-process-ledger"]' \
            --output "$evidence_directory/instruments/$prefix-ledger.xml" \
            >>"$log" 2>&1
        if (( $? != 0 )); then
            export_failures=$(( export_failures + 1 ))
        fi
        xcrun xctrace export --input "$trace" \
            --xpath '/trace-toc/run[@number="1"]/data/table[@schema="activity-monitor-process-live"]' \
            --output "$evidence_directory/instruments/$prefix-live.xml" \
            >>"$log" 2>&1
        if (( $? != 0 )); then
            export_failures=$(( export_failures + 1 ))
        fi
        xcrun xctrace export --input "$trace" \
            --xpath '/trace-toc/run[@number="1"]/data/table[@schema="device-thermal-state-intervals"]' \
            --output "$evidence_directory/instruments/$prefix-thermal.xml" \
            >>"$log" 2>&1
        if (( $? != 0 )); then
            export_failures=$(( export_failures + 1 ))
        fi
        local -a exported_files
        exported_files=("$evidence_directory/instruments/$prefix"*.xml(N))
        if (( ${#exported_files} > 0 )); then
            chmod 600 "${exported_files[@]}"
        fi
        if (( export_failures > 0 )); then
            print -u2 "warning: $export_failures Instruments exports failed for slice $index"
            capture_failures=$(( capture_failures + export_failures ))
        fi
    }

    local capture_index=0
    local offset
    for offset in "${capture_offsets[@]}"; do
        if [[ $offset != <-> || $offset -ge $duration_seconds ]]; then
            worker_cleanup_failure_reason="invalid_capture_offset"
            print -u2 "error: invalid capture offset: $offset"
            exit 64
        fi
        wait_until $(( start_epoch + offset )) || exit 1
        capture_index=$(( capture_index + 1 ))
        capture_instruments "$capture_index" "$offset"
    done

    wait_until "$end_epoch" || exit 1
    {
        print "capture_failures=$capture_failures"
        print "ready_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } >"$evidence_directory/capture-summary.txt"
    chmod 600 "$evidence_directory/capture-summary.txt"
    print "READY_TO_FINALIZE" >"$evidence_directory/run-status.txt"
    chmod 600 "$evidence_directory/run-status.txt"
    worker_cleanup_failure_reason="automatic_finalization_failed"
    finalize_command "$evidence_directory"
    worker_cleanup_completed=1
    remove_launchd_job
}

finalize_command() {
    if (( $# != 1 )); then
        usage
    fi
    local evidence_directory=$1
    require_absolute_directory "$evidence_directory"
    local state_file="$evidence_directory/run-status.txt"
    if [[ ! -f $state_file ||
          $(<"$state_file") != "READY_TO_FINALIZE" ]]; then
        print -u2 "error: run is not ready to finalize"
        exit 2
    fi

    local app_path="$evidence_directory/runtime/SpaceTrace.app"
    local analyzer="$evidence_directory/runtime/SpaceTraceSoakAnalyzer"
    local info_plist="$app_path/Contents/Info.plist"
    local bundle_identifier
    bundle_identifier=$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleIdentifier' "$info_plist")
    local app_pid
    app_pid=$(<"$evidence_directory/app.pid")
    if kill -0 "$app_pid" 2>/dev/null; then
        osascript -e "tell application id \"$bundle_identifier\" to quit" \
            >/dev/null 2>&1
        local quit_attempt
        for quit_attempt in {1..60}; do
            if ! kill -0 "$app_pid" 2>/dev/null; then
                break
            fi
            sleep 1
        done
    fi
    if kill -0 "$app_pid" 2>/dev/null; then
        print -u2 "error: SpaceTrace did not complete graceful shutdown"
        exit 1
    fi

    local diagnostics_directory="$HOME/Library/Containers/$bundle_identifier/Data/Library/Application Support/SpaceTrace/Diagnostics/BackgroundQualification"
    if [[ ! -d $diagnostics_directory ]]; then
        print -u2 "error: bounded diagnostic directory is unavailable"
        exit 1
    fi

    local privacy_status="PASS"
    if /usr/bin/grep -ERn \
        '/Users/|bookmark|volumeUUID|availableBytes|environment|commandLine|fileName|volumeName' \
        "$diagnostics_directory" \
        >"$evidence_directory/reports/privacy-scan.txt"
    then
        privacy_status="FAIL"
    fi
    {
        print "privacy_scan=$privacy_status"
        stat -f 'directory_mode=%Lp' "$diagnostics_directory"
        local diagnostic_file
        for diagnostic_file in "$diagnostics_directory"/*(.N); do
            stat -f 'file_mode=%Lp file=%N' "$diagnostic_file"
        done
        du -sh "$diagnostics_directory"
    } >"$evidence_directory/reports/diagnostic-storage.txt"
    chmod 600 "$evidence_directory/reports/"*.txt

    local -a analyzer_arguments
    analyzer_arguments=(
        --input "$diagnostics_directory"
        --output "$evidence_directory/reports/qualification-report.json"
    )
    local analyzer_smoke=${SPACETRACE_SOAK_ANALYZER_SMOKE_SECONDS:-}
    if [[ -n $analyzer_smoke ]]; then
        analyzer_arguments+=(--smoke "$analyzer_smoke")
    fi
    "$analyzer" "${analyzer_arguments[@]}" \
        >"$evidence_directory/reports/qualification-analyzer.log" 2>&1
    local analyzer_status=$?
    chmod 600 "$evidence_directory/reports/"*

    local capture_failures
    capture_failures=$(sed -n \
        's/^capture_failures=//p' \
        "$evidence_directory/capture-summary.txt")
    {
        print "capture_failures=$capture_failures"
        print "privacy_scan=$privacy_status"
        print "analyzer_exit_status=$analyzer_status"
        print "finished_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } >"$evidence_directory/final-summary.txt"
    chmod 600 "$evidence_directory/final-summary.txt"

    if [[ $capture_failures == "0" ]] &&
       [[ $privacy_status == "PASS" ]] &&
       (( analyzer_status == 0 )); then
        print "PASSED" >"$state_file"
        chmod 600 "$state_file"
        print "current-host soak: PASSED"
    else
        print "FAILED" >"$state_file"
        chmod 600 "$state_file"
        print -u2 "current-host soak: FAILED"
        exit 2
    fi
}

case $command_name in
    start)
        start_command "$@"
        ;;
    status)
        status_command "$@"
        ;;
    worker)
        worker_command "$@"
        ;;
    finalize)
        finalize_command "$@"
        ;;
    *)
        usage
        ;;
esac
