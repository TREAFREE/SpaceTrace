#!/bin/zsh

set -euo pipefail

program_name=${0:t}

if (( $# != 1 )); then
    print -u2 "usage: $program_name <semantic-version>"
    exit 64
fi

version=$1
script_directory=${0:A:h}
repository_root=${script_directory:h}
packager="$script_directory/package-release-candidate.sh"

cd "$repository_root"
[[ -z $(git status --porcelain=v1 --untracked-files=all) ]] || {
    print -u2 "error: packaging contract tests require a clean source tree"
    exit 2
}

temporary_root=$(mktemp -d /private/tmp/spacetrace-packaging-contract.XXXXXX)
dirty_probe="$repository_root/.spacetrace-packaging-dirty-probe-$$"
trap 'rm -f -- "$dirty_probe"; rm -rf -- "$temporary_root"' EXIT

expect_failure() {
    local label=$1
    shift
    if "$@" >/dev/null 2>&1; then
        print -u2 "error: expected failure: $label"
        exit 1
    fi
}

expect_failure "missing arguments" "$packager"
expect_failure "invalid semantic version" \
    "$packager" --version "not-a-version" --output "$temporary_root/invalid"

mkdir "$temporary_root/existing"
expect_failure "existing output" \
    "$packager" --version "$version" --output "$temporary_root/existing"

: >"$dirty_probe"
expect_failure "dirty source tree" \
    "$packager" --version "$version" --output "$temporary_root/dirty"
rm -f "$dirty_probe"

output="$temporary_root/release-candidate"
"$packager" --version "$version" --output "$output"

expected_entries=(
    "SpaceTrace-$version.app"
    "SpaceTrace-$version.dmg"
    "SpaceTrace-$version.manifest.json"
    "SpaceTrace-$version.sha256"
)
actual_entries=("${(@f)$(find "$output" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort)}")
[[ "${(j:\n:)actual_entries}" == "${(j:\n:)expected_entries}" ]] || {
    print -u2 "error: artifact set differs from the contract"
    print -u2 "actual: ${(j:, :)actual_entries}"
    exit 1
}

app_path="$output/SpaceTrace-$version.app"
dmg_path="$output/SpaceTrace-$version.dmg"
manifest_path="$output/SpaceTrace-$version.manifest.json"
checksum_path="$output/SpaceTrace-$version.sha256"

(
    cd "$output"
    shasum -a 256 -c "${checksum_path:t}"
)
codesign --verify --deep --strict --verbose=2 "$app_path"
hdiutil verify "$dmg_path" >/dev/null

[[ $(plutil -extract sourceTreeClean raw -o - "$manifest_path") == true ]]
[[ $(plutil -extract signing.mode raw -o - "$manifest_path") == adhoc ]]
[[ $(plutil -extract signing.developerId raw -o - "$manifest_path") == false ]]
[[ $(plutil -extract signing.hardenedRuntime raw -o - "$manifest_path") == true ]]
[[ $(plutil -extract signing.notarized raw -o - "$manifest_path") == false ]]
[[ $(plutil -extract minimumSystemVersion raw -o - "$manifest_path") == 15.6 ]]
[[ $(plutil -extract bundleIdentifier raw -o - "$manifest_path") == com.TREAFREE.SpaceTrace ]]
[[ $(plutil -extract architectures.0 raw -o - "$manifest_path") == arm64 ]]

signature_details=$(codesign -dvvv "$app_path" 2>&1)
[[ $signature_details == *"Signature=adhoc"* ]]
[[ $signature_details == *"TeamIdentifier=not set"* ]]
[[ $signature_details == *"runtime"* ]]
[[ $(lipo -archs "$app_path/Contents/MacOS/SpaceTrace") == arm64 ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app_path/Contents/Info.plist") == 15.6 ]]

print "release candidate packaging contract: PASS"
