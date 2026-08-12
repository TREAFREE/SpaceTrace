#!/bin/zsh

set -euo pipefail

program_name=${0:t}

usage() {
    print -u2 "usage: $program_name --version <semver> --output <new-directory>"
}

fail() {
    print -u2 "error: $1"
    exit "${2:-2}"
}

version=""
output=""

while (( $# > 0 )); do
    case "$1" in
        --version)
            (( $# >= 2 )) || { usage; exit 64; }
            version=$2
            shift 2
            ;;
        --output)
            (( $# >= 2 )) || { usage; exit 64; }
            output=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            print -u2 "error: unknown argument: $1"
            usage
            exit 64
            ;;
    esac
done

[[ -n $version && -n $output ]] || { usage; exit 64; }
print -r -- "$version" | /usr/bin/grep -Eq \
    '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$' \
    || fail "version must be valid Semantic Versioning" 64

script_directory=${0:A:h}
repository_root=${script_directory:h}
metadata_generator="$script_directory/generate-release-metadata.sh"
cd "$repository_root"

[[ $(git rev-parse --show-toplevel) == $repository_root ]] \
    || fail "script must run from the SpaceTrace Git worktree"
[[ -x $metadata_generator ]] || fail "release metadata generator is missing or not executable"
[[ -z $(git status --porcelain=v1 --untracked-files=all) ]] \
    || fail "release candidates require a clean source tree"

commit=$(git rev-parse HEAD)
build_version=$(git rev-list --count HEAD)
bundle_version=${version%%[-+]*}
bundle_identifier="com.TREAFREE.SpaceTrace"
minimum_system_version="15.6"
architecture="arm64"

if [[ $output == /* ]]; then
    output_path=$output
else
    output_path="$repository_root/$output"
fi
[[ ! -e $output_path ]] || fail "output already exists: $output_path"

output_parent=$(dirname "$output_path")
output_name=$(basename "$output_path")
[[ -n $output_name && $output_name != . && $output_name != .. ]] \
    || fail "output must name a new directory" 64
mkdir -p "$output_parent"
output_parent=$(cd "$output_parent" && pwd -P)
output_path="$output_parent/$output_name"

temporary_root=$(mktemp -d "$output_parent/.spacetrace-rc.XXXXXX")
trap 'rm -rf -- "$temporary_root"' EXIT

derived_data="$temporary_root/DerivedData"
artifact_stage="$temporary_root/artifacts"
dmg_stage="$temporary_root/dmg-root"
mkdir -p "$artifact_stage" "$dmg_stage"

print "building SpaceTrace $version from $commit"
xcodebuild -quiet \
    -project SpaceTrace.xcodeproj \
    -scheme SpaceTrace \
    -configuration Release \
    -destination "platform=macOS,arch=$architecture" \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    ARCHS="$architecture" \
    ONLY_ACTIVE_ARCH=YES \
    ENABLE_HARDENED_RUNTIME=YES \
    MARKETING_VERSION="$bundle_version" \
    CURRENT_PROJECT_VERSION="$build_version" \
    build

built_app="$derived_data/Build/Products/Release/SpaceTrace.app"
[[ -d $built_app ]] || fail "Release build did not produce SpaceTrace.app"

app_name="SpaceTrace-$version.app"
dmg_name="SpaceTrace-$version.dmg"
manifest_name="SpaceTrace-$version.manifest.json"
checksum_name="SpaceTrace-$version.sha256"
sbom_name="SpaceTrace-$version.spdx.json"
notices_name="SpaceTrace-$version.third-party-notices.txt"
app_path="$artifact_stage/$app_name"
dmg_path="$artifact_stage/$dmg_name"
manifest_path="$artifact_stage/$manifest_name"
checksum_path="$artifact_stage/$checksum_name"
sbom_path="$artifact_stage/$sbom_name"
notices_path="$artifact_stage/$notices_name"

/usr/bin/ditto "$built_app" "$app_path"
chmod -R u+rwX,go+rX,go-w "$app_path"

assert_exact_entitlements() {
    local source_plist=$1
    local label=$2
    local scratch="$temporary_root/${label//[^A-Za-z0-9]/-}-entitlements.plist"
    /bin/cp "$source_plist" "$scratch"

    local entitlement
    for entitlement in \
        com.apple.security.app-sandbox \
        com.apple.security.files.user-selected.read-write \
        com.apple.security.files.bookmarks.app-scope; do
        [[ $(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$scratch" 2>/dev/null) == true ]] \
            || fail "$label entitlement is missing or false: $entitlement"
        /usr/libexec/PlistBuddy -c "Delete :$entitlement" "$scratch"
    done

    [[ $(plutil -convert json -o - "$scratch") == "{}" ]] \
        || fail "$label contains an unexpected entitlement"
}

assert_exact_entitlements "SpaceTrace/SpaceTrace.entitlements" "source"

if codesign -d "$app_path" >/dev/null 2>&1; then
    initial_signature_details=$(codesign -dvvv "$app_path" 2>&1)
    [[ $initial_signature_details == *"Signature=adhoc"* ]] \
        || fail "Release build arrived with an unexpected signing authority"
    [[ $initial_signature_details == *"TeamIdentifier=not set"* ]] \
        || fail "Release build unexpectedly has a team signing identity"
fi

codesign --force --deep --sign - --timestamp=none --options runtime \
    --entitlements "SpaceTrace/SpaceTrace.entitlements" \
    "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

signature_details=$(codesign -dvvv "$app_path" 2>&1)
[[ $signature_details == *"Signature=adhoc"* ]] \
    || fail "final app is not ad-hoc signed"
[[ $signature_details == *"TeamIdentifier=not set"* ]] \
    || fail "final app unexpectedly has a team signing identity"
[[ $signature_details == *"runtime"* ]] \
    || fail "final app is missing Hardened Runtime"

extracted_entitlements="$temporary_root/final-entitlements.plist"
codesign -d --entitlements :- "$app_path" >"$extracted_entitlements" 2>/dev/null
assert_exact_entitlements "$extracted_entitlements" "final-app"

info_plist="$app_path/Contents/Info.plist"
actual_bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")
actual_bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")
actual_build_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")
actual_minimum_version=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info_plist")
actual_architectures=$(lipo -archs "$app_path/Contents/MacOS/SpaceTrace")

[[ $actual_bundle_identifier == $bundle_identifier ]] \
    || fail "unexpected bundle identifier: $actual_bundle_identifier"
[[ $actual_bundle_version == $bundle_version ]] \
    || fail "unexpected bundle version: $actual_bundle_version"
[[ $actual_build_version == $build_version ]] \
    || fail "unexpected build version: $actual_build_version"
[[ $actual_minimum_version == $minimum_system_version ]] \
    || fail "LSMinimumSystemVersion must be $minimum_system_version; found $actual_minimum_version"
[[ $actual_architectures == $architecture ]] \
    || fail "release candidate must contain only $architecture; found $actual_architectures"

embedded_dependency=$(find "$app_path/Contents" \
    \( -type d -name '*.framework' -o -type f -name '*.dylib' \) \
    -print -quit)
[[ -z $embedded_dependency ]] \
    || fail "release app embeds a framework or dynamic library: $embedded_dependency"

otool_output="$temporary_root/otool.txt"
otool -L "$app_path/Contents/MacOS/SpaceTrace" >"$otool_output"
/usr/bin/awk 'NR > 1 { print $1 }' "$otool_output" >"$temporary_root/dependencies.txt"
while IFS= read -r dependency; do
    [[ $dependency == /System/Library/* || $dependency == /usr/lib/* ]] \
        || fail "release app links a non-system dependency: $dependency"
done <"$temporary_root/dependencies.txt"

"$metadata_generator" \
    --version "$version" \
    --commit "$commit" \
    --sbom "$sbom_path" \
    --notices "$notices_path"

/usr/bin/ditto "$app_path" "$dmg_stage/SpaceTrace.app"
/bin/ln -s /Applications "$dmg_stage/Applications"
/bin/cp "$notices_path" "$dmg_stage/THIRD-PARTY-NOTICES.txt"
cat >"$dmg_stage/READ-ME-FIRST.txt" <<'NOTICE'
SpaceTrace release candidate / 测试候选版本

This build is ad-hoc signed and not notarized. macOS cannot verify its publisher.
Only continue if you trust the exact Git commit and have checked the published SHA-256.
Do not disable Gatekeeper globally.

此构建仅采用 ad-hoc 签名，且未经过 Apple 公证。macOS 无法验证发布者身份。
请只在信任对应 Git commit 并核对发布的 SHA-256 后继续，不要全局关闭 Gatekeeper。
NOTICE

hdiutil create -quiet \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -volname "SpaceTrace RC $version" \
    -srcfolder "$dmg_stage" \
    "$dmg_path"
hdiutil verify "$dmg_path" >/dev/null

dmg_sha256=$(shasum -a 256 "$dmg_path" | awk '{print $1}')
executable_sha256=$(shasum -a 256 "$app_path/Contents/MacOS/SpaceTrace" | awk '{print $1}')
sbom_sha256=$(shasum -a 256 "$sbom_path" | awk '{print $1}')
notices_sha256=$(shasum -a 256 "$notices_path" | awk '{print $1}')
xcode_version=$(xcodebuild -version | tr '\n' ' ' | sed 's/ $//')
host_version=$(sw_vers -productVersion)

manifest_plist="$temporary_root/manifest.plist"
plutil -create xml1 "$manifest_plist"
plutil -insert schemaVersion -integer 1 "$manifest_plist"
plutil -insert releaseVersion -string "$version" "$manifest_plist"
plutil -insert bundleVersion -string "$bundle_version" "$manifest_plist"
plutil -insert buildVersion -string "$build_version" "$manifest_plist"
plutil -insert bundleIdentifier -string "$bundle_identifier" "$manifest_plist"
plutil -insert sourceCommit -string "$commit" "$manifest_plist"
plutil -insert sourceTreeClean -bool true "$manifest_plist"
plutil -insert minimumSystemVersion -string "$minimum_system_version" "$manifest_plist"
plutil -insert architectures -json '["arm64"]' "$manifest_plist"
plutil -insert entitlements -json \
    '["com.apple.security.app-sandbox","com.apple.security.files.user-selected.read-write","com.apple.security.files.bookmarks.app-scope"]' \
    "$manifest_plist"
plutil -insert signing -dictionary "$manifest_plist"
plutil -insert signing.mode -string adhoc "$manifest_plist"
plutil -insert signing.developerId -bool false "$manifest_plist"
plutil -insert signing.hardenedRuntime -bool true "$manifest_plist"
plutil -insert signing.notarized -bool false "$manifest_plist"
plutil -insert gatekeeperAssessment -string expected-rejected-unnotarized "$manifest_plist"
plutil -insert artifacts -dictionary "$manifest_plist"
plutil -insert artifacts.app -string "$app_name" "$manifest_plist"
plutil -insert artifacts.dmg -string "$dmg_name" "$manifest_plist"
plutil -insert artifacts.dmgSha256 -string "$dmg_sha256" "$manifest_plist"
plutil -insert artifacts.executableSha256 -string "$executable_sha256" "$manifest_plist"
plutil -insert artifacts.sbom -string "$sbom_name" "$manifest_plist"
plutil -insert artifacts.sbomSha256 -string "$sbom_sha256" "$manifest_plist"
plutil -insert artifacts.thirdPartyNotices -string "$notices_name" "$manifest_plist"
plutil -insert artifacts.thirdPartyNoticesSha256 -string "$notices_sha256" "$manifest_plist"
plutil -insert buildEnvironment -dictionary "$manifest_plist"
plutil -insert buildEnvironment.hostOS -string "$host_version" "$manifest_plist"
plutil -insert buildEnvironment.xcode -string "$xcode_version" "$manifest_plist"
plutil -insert reproducibility -string \
    "source-and-contract reproducible; compressed DMG bytes are not claimed bit-for-bit deterministic" \
    "$manifest_plist"
plutil -convert json -o "$manifest_path" "$manifest_plist"

(
    cd "$artifact_stage"
    shasum -a 256 \
        "$dmg_name" \
        "$manifest_name" \
        "$sbom_name" \
        "$notices_name" >"$checksum_name"
    shasum -a 256 -c "$checksum_name"
)

artifact_count=$(find "$artifact_stage" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
[[ $artifact_count == 6 ]] || fail "unexpected artifact count: $artifact_count"

chmod 0644 "$dmg_path" "$manifest_path" "$checksum_path" "$sbom_path" "$notices_path"
/bin/mv "$artifact_stage" "$output_path"

print "release candidate packaging: PASS"
print "output: $output_path"
print "commit: $commit"
print "mode: ad-hoc signed, Hardened Runtime, not notarized"
print "warning: this artifact is not Apple-verified and is not a stable public release"
