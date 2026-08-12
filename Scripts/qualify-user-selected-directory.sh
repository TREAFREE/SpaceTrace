#!/bin/zsh

set -euo pipefail

if (( $# != 1 )); then
    print -u2 "usage: $0 /absolute/path/to/SpaceTrace.app"
    exit 64
fi

app_path=$1
if [[ $app_path != /* || ! -d $app_path ]]; then
    print -u2 "error: app path must be an existing absolute .app directory"
    exit 64
fi

host_version=$(sw_vers -productVersion)
host_arch=$(uname -m)
required_version=${SPACETRACE_REQUIRED_OS_VERSION:-15.6}
allow_newer_smoke=${SPACETRACE_ALLOW_NEWER_HOST_SMOKE:-0}
allow_adhoc_smoke=${SPACETRACE_ALLOW_ADHOC_SMOKE:-0}

if [[ $host_arch != arm64 ]]; then
    print -u2 "error: Public Beta qualification requires Apple Silicon; found $host_arch"
    exit 2
fi

if [[ $host_version != ${required_version} && $host_version != ${required_version}.* ]]; then
    if [[ $allow_newer_smoke != 1 ]]; then
        print -u2 "error: qualification requires macOS $required_version.x; found $host_version"
        print -u2 "hint: set SPACETRACE_ALLOW_NEWER_HOST_SMOKE=1 for a non-qualifying smoke preflight"
        exit 2
    fi
    print "warning: running a newer-host smoke preflight on macOS $host_version"
    print "warning: this result is not macOS $required_version runtime qualification"
fi

codesign --verify --deep --strict --verbose=2 "$app_path"

signature_details=$(codesign -dvvv "$app_path" 2>&1)
if [[ $signature_details == *"Signature=adhoc"* ]]; then
    if [[ $allow_adhoc_smoke != 1 ]]; then
        print -u2 "error: official qualification requires a stable Apple signing identity"
        print -u2 "hint: set SPACETRACE_ALLOW_ADHOC_SMOKE=1 for a non-distribution smoke preflight"
        exit 2
    fi
    print "warning: ad-hoc signature accepted for local smoke preflight only"
fi

entitlements_file=$(mktemp /private/tmp/spacetrace-entitlements.XXXXXX.plist)
trap 'rm -f "$entitlements_file"' EXIT
codesign -d --entitlements :- "$app_path" >"$entitlements_file" 2>/dev/null

read_entitlement() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$entitlements_file" 2>/dev/null
}

for entitlement in \
    com.apple.security.app-sandbox \
    com.apple.security.files.user-selected.read-write \
    com.apple.security.files.bookmarks.app-scope; do
    if [[ $(read_entitlement "$entitlement") != true ]]; then
        print -u2 "error: required entitlement missing or false: $entitlement"
        exit 3
    fi
done

minimum_version=$(/usr/libexec/PlistBuddy \
    -c 'Print :LSMinimumSystemVersion' \
    "$app_path/Contents/Info.plist")
if [[ $minimum_version != 15.6 ]]; then
    print -u2 "error: LSMinimumSystemVersion must be 15.6; found $minimum_version"
    exit 3
fi

print "preflight: PASS"
print "host: macOS $host_version ($host_arch)"
print "bundle: $app_path"
print "minimum system: $minimum_version"
print "next: execute docs/engineering/user-selected-directory-qualification.md"
