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
metadata_generator="$script_directory/generate-release-metadata.sh"

cd "$repository_root"
[[ -z $(git status --porcelain=v1 --untracked-files=all) ]] || {
    print -u2 "error: packaging contract tests require a clean source tree"
    exit 2
}

temporary_root=$(mktemp -d /private/tmp/spacetrace-packaging-contract.XXXXXX)
dirty_probe="$repository_root/.spacetrace-packaging-dirty-probe-$$"
mounted_path=""

cleanup() {
    if [[ -n $mounted_path && -d $mounted_path ]]; then
        hdiutil detach -force "$mounted_path" >/dev/null 2>&1 || true
    fi
    rm -f -- "$dirty_probe"
    rm -rf -- "$temporary_root"
}
trap cleanup EXIT

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

valid_commit=$(git rev-parse HEAD)
mkdir "$temporary_root/generator-a" "$temporary_root/generator-b"
expect_failure "metadata invalid semantic version" \
    "$metadata_generator" \
    --version "not-a-version" \
    --commit "$valid_commit" \
    --sbom "$temporary_root/generator-a/invalid.spdx.json" \
    --notices "$temporary_root/generator-a/invalid.notices.txt"
expect_failure "metadata invalid commit" \
    "$metadata_generator" \
    --version "$version" \
    --commit "not-a-40-hex-commit" \
    --sbom "$temporary_root/generator-a/invalid-commit.spdx.json" \
    --notices "$temporary_root/generator-a/invalid-commit.notices.txt"

: >"$temporary_root/generator-a/existing.spdx.json"
expect_failure "metadata existing SBOM output" \
    "$metadata_generator" \
    --version "$version" \
    --commit "$valid_commit" \
    --sbom "$temporary_root/generator-a/existing.spdx.json" \
    --notices "$temporary_root/generator-a/existing-sbom.notices.txt"
: >"$temporary_root/generator-a/existing.notices.txt"
expect_failure "metadata existing notices output" \
    "$metadata_generator" \
    --version "$version" \
    --commit "$valid_commit" \
    --sbom "$temporary_root/generator-a/existing-notices.spdx.json" \
    --notices "$temporary_root/generator-a/existing.notices.txt"

for directory in generator-a generator-b; do
    "$metadata_generator" \
        --version "$version" \
        --commit "$valid_commit" \
        --sbom "$temporary_root/$directory/SpaceTrace.spdx.json" \
        --notices "$temporary_root/$directory/THIRD-PARTY-NOTICES.txt"
done
[[ $(/usr/bin/plutil -extract spdxVersion raw -o - \
    "$temporary_root/generator-a/SpaceTrace.spdx.json") == SPDX-2.3 ]]
cmp "$temporary_root/generator-a/SpaceTrace.spdx.json" \
    "$temporary_root/generator-b/SpaceTrace.spdx.json"
cmp "$temporary_root/generator-a/THIRD-PARTY-NOTICES.txt" \
    "$temporary_root/generator-b/THIRD-PARTY-NOTICES.txt"
if /usr/bin/grep -Fq "$repository_root" \
    "$temporary_root/generator-a/SpaceTrace.spdx.json" \
    "$temporary_root/generator-a/THIRD-PARTY-NOTICES.txt"; then
    print -u2 "error: generated release metadata contains the repository path"
    exit 1
fi

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
    "SpaceTrace-$version.spdx.json"
    "SpaceTrace-$version.third-party-notices.txt"
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
sbom_path="$output/SpaceTrace-$version.spdx.json"
notices_path="$output/SpaceTrace-$version.third-party-notices.txt"

(
    cd "$output"
    shasum -a 256 -c "${checksum_path:t}"
)
[[ $(wc -l <"$checksum_path" | tr -d ' ') == 4 ]]
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
[[ $(plutil -extract artifacts.sbom raw -o - "$manifest_path") == "${sbom_path:t}" ]]
[[ $(plutil -extract artifacts.thirdPartyNotices raw -o - "$manifest_path") == "${notices_path:t}" ]]
[[ $(plutil -extract artifacts.sbomSha256 raw -o - "$manifest_path") == \
    $(shasum -a 256 "$sbom_path" | /usr/bin/awk '{ print $1 }') ]]
[[ $(plutil -extract artifacts.thirdPartyNoticesSha256 raw -o - "$manifest_path") == \
    $(shasum -a 256 "$notices_path" | /usr/bin/awk '{ print $1 }') ]]
[[ $(plutil -extract spdxVersion raw -o - "$sbom_path") == SPDX-2.3 ]]
[[ $(plutil -extract dataLicense raw -o - "$sbom_path") == CC0-1.0 ]]
[[ $(plutil -extract packages.0.versionInfo raw -o - "$sbom_path") == "$version" ]]
[[ $(plutil -extract packages.0.licenseDeclared raw -o - "$sbom_path") == NOASSERTION ]]
[[ $(plutil -extract packages.0.filesAnalyzed raw -o - "$sbom_path") == false ]]
grep -Fq 'No third-party libraries are embedded in SpaceTrace.app.' "$notices_path"

signature_details=$(codesign -dvvv "$app_path" 2>&1)
[[ $signature_details == *"Signature=adhoc"* ]]
[[ $signature_details == *"TeamIdentifier=not set"* ]]
[[ $signature_details == *"runtime"* ]]
[[ $(lipo -archs "$app_path/Contents/MacOS/SpaceTrace") == arm64 ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app_path/Contents/Info.plist") == 15.6 ]]

embedded_dependency=$(find "$app_path/Contents" \
    \( -type d -name '*.framework' -o -type f -name '*.dylib' \) \
    -print -quit)
[[ -z $embedded_dependency ]] || {
    print -u2 "error: release app embeds a framework or dynamic library"
    exit 1
}

otool_output="$temporary_root/otool.txt"
otool -L "$app_path/Contents/MacOS/SpaceTrace" >"$otool_output"
while IFS= read -r dependency; do
    [[ $dependency == /System/Library/* || $dependency == /usr/lib/* ]] || {
        print -u2 "error: release app links a non-system dependency"
        exit 1
    }
done < <(/usr/bin/awk 'NR > 1 { print $1 }' "$otool_output")

mounted_path="$temporary_root/mounted-dmg"
mkdir "$mounted_path"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mounted_path" "$dmg_path"
[[ -d "$mounted_path/SpaceTrace.app" ]]
[[ -L "$mounted_path/Applications" ]]
[[ -f "$mounted_path/READ-ME-FIRST.txt" ]]
cmp "$notices_path" "$mounted_path/THIRD-PARTY-NOTICES.txt"
hdiutil detach "$mounted_path" >/dev/null
mounted_path=""

print "release candidate packaging contract: PASS"
