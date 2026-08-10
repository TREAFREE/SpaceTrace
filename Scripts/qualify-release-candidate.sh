#!/bin/zsh

set -euo pipefail

program_name=${0:t}
script_directory=${0:A:h}

usage() {
    print -u2 "usage: $program_name --primary <absolute-app-path> --replacement <absolute-app-path>"
}

primary_app=""
replacement_app=""

while (( $# > 0 )); do
    case "$1" in
        --primary)
            (( $# >= 2 )) || { usage; exit 64; }
            primary_app=$2
            shift 2
            ;;
        --replacement)
            (( $# >= 2 )) || { usage; exit 64; }
            replacement_app=$2
            shift 2
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

for app_path in "$primary_app" "$replacement_app"; do
    [[ $app_path == /* && -d $app_path ]] || {
        print -u2 "error: both app paths must be existing absolute directories"
        exit 64
    }
    codesign --verify --deep --strict --verbose=2 "$app_path"
done

primary_sha=$(shasum -a 256 "$primary_app/Contents/MacOS/SpaceTrace" | awk '{print $1}')
replacement_sha=$(shasum -a 256 "$replacement_app/Contents/MacOS/SpaceTrace" | awk '{print $1}')
[[ $primary_sha != $replacement_sha ]] || {
    print -u2 "error: replacement matrix requires two independently built binaries"
    exit 2
}

run_id="run$(date -u '+%Y%m%d%H%M%S')p$$"
bundle_identifier="com.TREAFREE.SpaceTrace.RCQualification.$run_id"
container_path="$HOME/Library/Containers/$bundle_identifier"
[[ $bundle_identifier == com.TREAFREE.SpaceTrace.RCQualification.run* ]] || exit 2
[[ ! -e $container_path ]] || {
    print -u2 "error: disposable container already exists: $container_path"
    exit 2
}

temporary_root=$(mktemp -d /private/tmp/spacetrace-rc-qualification.XXXXXX)
runtime_app="$temporary_root/SpaceTrace.app"
current_pid=""

stop_runtime() {
    if [[ -n $current_pid ]] && kill -0 "$current_pid" 2>/dev/null; then
        osascript -e "tell application id \"$bundle_identifier\" to quit" \
            >/dev/null 2>&1 || true
        local attempt
        for attempt in {1..30}; do
            kill -0 "$current_pid" 2>/dev/null || break
            sleep 0.2
        done
    fi
    if [[ -n $current_pid ]] && kill -0 "$current_pid" 2>/dev/null; then
        kill -TERM "$current_pid" 2>/dev/null || true
    fi
    current_pid=""
}

cleanup() {
    stop_runtime
    rm -rf -- "$temporary_root"
}
trap cleanup EXIT INT TERM HUP

prepare_runtime() {
    local source_app=$1
    rm -rf -- "$runtime_app"
    /usr/bin/ditto "$source_app" "$runtime_app"
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleIdentifier $bundle_identifier" \
        "$runtime_app/Contents/Info.plist"
    codesign --force --deep --sign - --timestamp=none --options runtime \
        --entitlements "$script_directory/../SpaceTrace/SpaceTrace.entitlements" \
        "$runtime_app"
    codesign --verify --deep --strict --verbose=2 "$runtime_app"
}

launch_and_stop() {
    local label=$1
    local binary_path="$runtime_app/Contents/MacOS/SpaceTrace"
    open -n "$runtime_app"

    local attempt
    for attempt in {1..50}; do
        current_pid=$(pgrep -f "$binary_path" | head -1 || true)
        if [[ -n $current_pid ]] && kill -0 "$current_pid" 2>/dev/null; then
            break
        fi
        current_pid=""
        sleep 0.2
    done
    [[ -n $current_pid ]] || {
        print -u2 "error: $label did not launch"
        exit 1
    }

    sleep 1
    kill -0 "$current_pid" 2>/dev/null || {
        print -u2 "error: $label exited unexpectedly"
        exit 1
    }
    print "$label: launched (pid $current_pid)"
    stop_runtime
    print "$label: graceful quit"
}

prepare_runtime "$primary_app"
launch_and_stop "fresh-install"
launch_and_stop "same-build-restart"

prepare_runtime "$replacement_app"
launch_and_stop "independent-build-replacement"

[[ -d $container_path ]] || {
    print -u2 "error: sandbox container was not created"
    exit 1
}

if ! /usr/bin/trash "$container_path"; then
    print -u2 "error: container-cleanup-blocked-by-macos-privacy"
    print -u2 "container: $container_path"
    print -u2 "action: remove only this exact disposable container with explicit user-authorized Full Disk Access"
    exit 3
fi
[[ ! -e $container_path ]] || {
    print -u2 "error: disposable sandbox container remained after trash accepted it"
    exit 3
}

print "release candidate launch/replacement qualification: PASS"
print "bundle: $bundle_identifier"
print "primary executable: $primary_sha"
print "replacement executable: $replacement_sha"
print "container cleanup: PASS"
print "non-claim: no directory was selected, so bookmark continuity remains open"
