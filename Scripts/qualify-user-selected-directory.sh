#!/bin/zsh

set -euo pipefail

program_name=${0:t}

usage() {
    print -u2 \
        "usage: $program_name --app <absolute-app> --manifest <absolute-manifest> --distribution-mode adhoc-public-beta --accept-risk --output <new-absolute-json> [--allow-newer-host-smoke]"
}

fail() {
    print -u2 "user-selected directory preflight: NO-GO ($1)"
    exit "${2:-2}"
}

app_path=""
manifest_path=""
distribution_mode=""
output_path=""
accept_risk=false
allow_newer_host_smoke=false

while (( $# > 0 )); do
    case "$1" in
        --app)
            (( $# >= 2 )) || { usage; exit 64; }
            app_path=$2
            shift 2
            ;;
        --manifest)
            (( $# >= 2 )) || { usage; exit 64; }
            manifest_path=$2
            shift 2
            ;;
        --distribution-mode)
            (( $# >= 2 )) || { usage; exit 64; }
            distribution_mode=$2
            shift 2
            ;;
        --accept-risk)
            accept_risk=true
            shift
            ;;
        --output)
            (( $# >= 2 )) || { usage; exit 64; }
            output_path=$2
            shift 2
            ;;
        --allow-newer-host-smoke)
            allow_newer_host_smoke=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

[[ -n $app_path && -n $manifest_path && -n $distribution_mode \
    && -n $output_path && $accept_risk == true ]] \
    || { usage; exit 64; }
[[ $distribution_mode == adhoc-public-beta ]] \
    || fail "distribution contract" 64
[[ $app_path == /* && -d $app_path && ! -L $app_path && $app_path == *.app ]] \
    || fail "app contract" 64
[[ $manifest_path == /* && -f $manifest_path && ! -L $manifest_path ]] \
    || fail "manifest contract" 64
[[ $output_path == /* && ! -e $output_path && ! -L $output_path ]] \
    || fail "output contract" 64
[[ $(/usr/bin/stat -f '%z' "$manifest_path" 2>/dev/null) -le 65536 ]] \
    || fail "manifest contract"

output_parent=${output_path:h}
output_name=${output_path:t}
[[ -d $output_parent && ! -L $output_parent \
    && -n $output_name && $output_name != . && $output_name != .. ]] \
    || fail "output contract" 64
output_parent=$(cd "$output_parent" && pwd -P) \
    || fail "output contract" 64
output_path="$output_parent/$output_name"

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/spacetrace-directory-preflight.XXXXXX") \
    || fail "temporary evidence contract"
temporary_output=""
cleanup() {
    [[ -z $temporary_output ]] || /bin/rm -f -- "$temporary_output"
    /bin/rm -rf -- "$temporary_root"
}
trap cleanup EXIT INT TERM HUP

plist_value() {
    local file=$1
    local key=$2
    local type=$3
    plutil -extract "$key" raw -expect "$type" -o - "$file" 2>/dev/null
}

assert_exact_keys() {
    local plist=$1
    shift
    local expected actual
    expected=$(printf '%s\n' "$@" | LC_ALL=C /usr/bin/sort)
    actual=$(/usr/bin/sed -n \
        's/^[[:space:]]*<key>\([^<]*\)<\/key>[[:space:]]*$/\1/p' \
        "$plist" | LC_ALL=C /usr/bin/sort)
    [[ $actual == $expected ]] || fail "manifest contract"
}

manifest_text=$(<"$manifest_path")
readonly manifest_keys=(
    schemaVersion
    releaseVersion
    bundleVersion
    buildVersion
    bundleIdentifier
    sourceCommit
    sourceTreeClean
    minimumSystemVersion
    architectures
    entitlements
    signing
    gatekeeperAssessment
    artifacts
    buildEnvironment
    reproducibility
)
readonly signing_keys=(mode developerId hardenedRuntime notarized)
readonly artifact_keys=(
    app
    dmg
    dmgSha256
    executableSha256
    sbom
    sbomSha256
    thirdPartyNotices
    thirdPartyNoticesSha256
)
readonly build_environment_keys=(hostOS xcode)

for key in "${manifest_keys[@]}" "${signing_keys[@]}" \
    "${artifact_keys[@]}" "${build_environment_keys[@]}"; do
    occurrence_count=$(print -r -- "$manifest_text" \
        | /usr/bin/grep -Eo "\"$key\"[[:space:]]*:" \
        | /usr/bin/wc -l | /usr/bin/tr -d ' ') || occurrence_count=0
    occurrence_count=${occurrence_count:-0}
    [[ $occurrence_count == 1 ]] || fail "manifest contract"
done

top_level_plist="$temporary_root/manifest-top-level.plist"
plutil -convert xml1 -o "$top_level_plist" "$manifest_path" >/dev/null 2>&1 \
    || fail "manifest contract"
for nested_key in architectures entitlements signing artifacts buildEnvironment; do
    plutil -replace "$nested_key" -string omitted "$top_level_plist" \
        >/dev/null 2>&1 || fail "manifest contract"
done
assert_exact_keys "$top_level_plist" "${manifest_keys[@]}"

signing_plist="$temporary_root/manifest-signing.plist"
artifact_plist="$temporary_root/manifest-artifacts.plist"
build_environment_plist="$temporary_root/manifest-build-environment.plist"
plutil -extract signing xml1 -o "$signing_plist" "$manifest_path" \
    >/dev/null 2>&1 || fail "manifest contract"
plutil -extract artifacts xml1 -o "$artifact_plist" "$manifest_path" \
    >/dev/null 2>&1 || fail "manifest contract"
plutil -extract buildEnvironment xml1 -o "$build_environment_plist" \
    "$manifest_path" >/dev/null 2>&1 || fail "manifest contract"
assert_exact_keys "$signing_plist" "${signing_keys[@]}"
assert_exact_keys "$artifact_plist" "${artifact_keys[@]}"
assert_exact_keys "$build_environment_plist" "${build_environment_keys[@]}"

manifest_schema=$(plist_value "$manifest_path" schemaVersion integer) \
    || fail "manifest contract"
release_version=$(plist_value "$manifest_path" releaseVersion string) \
    || fail "manifest contract"
bundle_version=$(plist_value "$manifest_path" bundleVersion string) \
    || fail "manifest contract"
build_version=$(plist_value "$manifest_path" buildVersion string) \
    || fail "manifest contract"
bundle_identifier=$(plist_value "$manifest_path" bundleIdentifier string) \
    || fail "manifest contract"
source_commit=$(plist_value "$manifest_path" sourceCommit string) \
    || fail "manifest contract"
source_tree_clean=$(plist_value "$manifest_path" sourceTreeClean bool) \
    || fail "manifest contract"
minimum_system_version=$(plist_value "$manifest_path" minimumSystemVersion string) \
    || fail "manifest contract"
manifest_app=$(plist_value "$manifest_path" artifacts.app string) \
    || fail "manifest contract"
manifest_executable_sha=$(plist_value \
    "$manifest_path" artifacts.executableSha256 string) \
    || fail "manifest contract"
signing_mode=$(plist_value "$manifest_path" signing.mode string) \
    || fail "manifest contract"
developer_id=$(plist_value "$manifest_path" signing.developerId bool) \
    || fail "manifest contract"
hardened_runtime=$(plist_value "$manifest_path" signing.hardenedRuntime bool) \
    || fail "manifest contract"
notarized=$(plist_value "$manifest_path" signing.notarized bool) \
    || fail "manifest contract"
gatekeeper_assessment=$(plist_value \
    "$manifest_path" gatekeeperAssessment string) \
    || fail "manifest contract"
manifest_architectures=$(plutil -extract architectures json -o - \
    "$manifest_path" 2>/dev/null) || fail "manifest contract"
manifest_entitlements=$(plutil -extract entitlements json -o - \
    "$manifest_path" 2>/dev/null) || fail "manifest contract"

[[ $manifest_schema == 1 \
    && $source_tree_clean == true \
    && $minimum_system_version == 15.6 \
    && $manifest_app == ${app_path:t} \
    && $signing_mode == adhoc \
    && $developer_id == false \
    && $hardened_runtime == true \
    && $notarized == false \
    && $gatekeeper_assessment == expected-rejected-unnotarized \
    && $manifest_architectures == '["arm64"]' \
    && $manifest_entitlements == '["com.apple.security.app-sandbox","com.apple.security.files.user-selected.read-write","com.apple.security.files.bookmarks.app-scope"]' ]] \
    || fail "manifest contract"
print -r -- "$release_version" | /usr/bin/grep -Eq \
    '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$' \
    || fail "manifest contract"
print -r -- "$source_commit" | /usr/bin/grep -Eq '^[0-9a-f]{40}$' \
    || fail "manifest contract"
print -r -- "$manifest_executable_sha" \
    | /usr/bin/grep -Eq '^[0-9a-f]{64}$' \
    || fail "manifest contract"

info_plist="$app_path/Contents/Info.plist"
executable_path="$app_path/Contents/MacOS/SpaceTrace"
[[ -f $info_plist && ! -L $info_plist \
    && -f $executable_path && ! -L $executable_path ]] \
    || fail "app contract"

actual_bundle_identifier=$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null) \
    || fail "app metadata contract"
actual_executable_name=$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleExecutable' "$info_plist" 2>/dev/null) \
    || fail "app metadata contract"
actual_bundle_version=$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null) \
    || fail "app metadata contract"
actual_build_version=$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleVersion' "$info_plist" 2>/dev/null) \
    || fail "app metadata contract"
actual_minimum_version=$(/usr/libexec/PlistBuddy \
    -c 'Print :LSMinimumSystemVersion' "$info_plist" 2>/dev/null) \
    || fail "app metadata contract"
actual_architectures=$(lipo -archs "$executable_path" 2>/dev/null) \
    || fail "app architecture contract"
actual_executable_sha=$(/usr/bin/shasum -a 256 "$executable_path" \
    | /usr/bin/awk '{print $1}') || fail "app hash contract"

[[ $actual_bundle_identifier == $bundle_identifier \
    && $actual_bundle_identifier == com.TREAFREE.SpaceTrace \
    && $actual_executable_name == SpaceTrace \
    && $actual_bundle_version == $bundle_version \
    && $actual_build_version == $build_version \
    && $actual_minimum_version == 15.6 \
    && $actual_architectures == arm64 \
    && $actual_executable_sha == $manifest_executable_sha ]] \
    || fail "app binding contract"

codesign --verify --deep --strict "$app_path" >/dev/null 2>&1 \
    || fail "signature contract"
signature_details=$(codesign -dvvv "$app_path" 2>&1) \
    || fail "signature contract"
signature_value=$(print -r -- "$signature_details" \
    | /usr/bin/sed -n 's/^Signature=//p')
team_identifier=$(print -r -- "$signature_details" \
    | /usr/bin/sed -n 's/^TeamIdentifier=//p')
signature_occurrences=$(print -r -- "$signature_details" \
    | /usr/bin/grep -Ec '^Signature=') || signature_occurrences=0
team_occurrences=$(print -r -- "$signature_details" \
    | /usr/bin/grep -Ec '^TeamIdentifier=') || team_occurrences=0
runtime_occurrences=$(print -r -- "$signature_details" \
    | /usr/bin/grep -Ec \
        '^CodeDirectory .*flags=.*\(([^,)]*,)*runtime(,|\))') \
    || runtime_occurrences=0
[[ $signature_occurrences == 1 \
    && $team_occurrences == 1 \
    && $runtime_occurrences == 1 \
    && $signature_value == adhoc \
    && $team_identifier == 'not set' ]] \
    || fail "signature contract"

entitlements_file="$temporary_root/entitlements.plist"
codesign -d --entitlements :- "$app_path" >"$entitlements_file" 2>/dev/null \
    || fail "entitlement contract"
for entitlement in \
    com.apple.security.app-sandbox \
    com.apple.security.files.user-selected.read-write \
    com.apple.security.files.bookmarks.app-scope; do
    [[ $(/usr/libexec/PlistBuddy -c "Print :$entitlement" \
        "$entitlements_file" 2>/dev/null) == true ]] \
        || fail "entitlement contract"
    /usr/libexec/PlistBuddy -c "Delete :$entitlement" \
        "$entitlements_file" >/dev/null 2>&1 \
        || fail "entitlement contract"
done
[[ $(plutil -convert json -o - "$entitlements_file" 2>/dev/null) == '{}' ]] \
    || fail "entitlement contract"

host_product_version=$(sw_vers -productVersion 2>/dev/null) \
    || fail "host contract"
host_build_version=$(sw_vers -buildVersion 2>/dev/null) \
    || fail "host contract"
host_architecture=$(uname -m 2>/dev/null) || fail "host contract"
print -r -- "$host_product_version" \
    | /usr/bin/grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
    || fail "host contract"
[[ -n $host_build_version && $host_architecture == arm64 ]] \
    || fail "host contract"

host_major=${host_product_version%%.*}
host_remainder=${host_product_version#*.}
host_minor=${host_remainder%%.*}
qualification_status=""
if (( host_major == 15 && host_minor == 6 )); then
    qualification_status=passed
elif (( host_major > 15 || (host_major == 15 && host_minor > 6) )); then
    [[ $allow_newer_host_smoke == true ]] || fail "minimum OS contract"
    qualification_status=smoke
else
    fail "minimum OS contract"
fi

manifest_sha=$(/usr/bin/shasum -a 256 "$manifest_path" \
    | /usr/bin/awk '{print $1}') || fail "manifest hash contract"

report_plist="$temporary_root/report.plist"
plutil -create xml1 "$report_plist" || fail "report contract"
plutil -insert schemaVersion -integer 1 "$report_plist"
plutil -insert qualificationType -string minimum-os-app-preflight "$report_plist"
plutil -insert status -string "$qualification_status" "$report_plist"
plutil -insert releaseVersion -string "$release_version" "$report_plist"
plutil -insert sourceCommit -string "$source_commit" "$report_plist"
plutil -insert manifestSha256 -string "$manifest_sha" "$report_plist"
plutil -insert executableSha256 -string "$actual_executable_sha" "$report_plist"
plutil -insert distributionMode -string adhoc-public-beta "$report_plist"
plutil -insert distributionRiskAccepted -bool true "$report_plist"
plutil -insert hostProductVersion -string "$host_product_version" "$report_plist"
plutil -insert hostBuildVersion -string "$host_build_version" "$report_plist"
plutil -insert hostArchitecture -string arm64 "$report_plist"
plutil -insert bundleIdentifier -string "$bundle_identifier" "$report_plist"
plutil -insert bundleVersion -string "$bundle_version" "$report_plist"
plutil -insert buildVersion -string "$build_version" "$report_plist"
plutil -insert minimumSystemVersion -string 15.6 "$report_plist"
plutil -insert signatureMode -string adhoc "$report_plist"
plutil -insert teamIdentifier -string not-set "$report_plist"
plutil -insert hardenedRuntime -bool true "$report_plist"
plutil -insert entitlements -json \
    '["com.apple.security.app-sandbox","com.apple.security.files.user-selected.read-write","com.apple.security.files.bookmarks.app-scope"]' \
    "$report_plist"
plutil -insert qualificationScope -string automated-preflight-only "$report_plist"
plutil -insert manualMatrix -string required:q01-q06 "$report_plist"

temporary_output=$(mktemp "$output_parent/.spacetrace-directory-preflight.XXXXXX") \
    || fail "output contract"
plutil -convert json -o "$temporary_output" "$report_plist" >/dev/null 2>&1 \
    || fail "report contract"
/bin/chmod 600 "$temporary_output" || fail "output contract"
/bin/ln "$temporary_output" "$output_path" || fail "output contract"
/bin/rm -f -- "$temporary_output" || fail "output contract"
temporary_output=""

if [[ $qualification_status == passed ]]; then
    print "user-selected directory preflight: PASS"
else
    print "user-selected directory preflight: SMOKE"
    print "qualification boundary: newer host does not qualify macOS 15.6"
fi
