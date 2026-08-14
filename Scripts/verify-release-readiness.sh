#!/bin/zsh

set -euo pipefail

program_name=${0:t}

usage() {
    print -u2 "usage: $program_name --qualification <qualification.json> --artifacts <release-directory>"
}

nogo() {
    print "release readiness: NO-GO ($1)"
    exit 1
}

qualification=""
artifacts=""

while (( $# > 0 )); do
    case "$1" in
        --qualification)
            (( $# >= 2 )) || { usage; exit 64; }
            qualification=$2
            shift 2
            ;;
        --artifacts)
            (( $# >= 2 )) || { usage; exit 64; }
            artifacts=$2
            shift 2
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

[[ -n $qualification && -n $artifacts ]] || { usage; exit 64; }
[[ $qualification == /* && $artifacts == /* ]] || nogo "qualification contract"
[[ -f $qualification && ! -L $qualification ]] || nogo "qualification contract"
[[ -d $artifacts && ! -L $artifacts ]] || nogo "artifact contract"
[[ $(/usr/bin/stat -f '%z' "$qualification" 2>/dev/null) -le 65536 ]] \
    || nogo "qualification contract"

qualification_text=$(<"$qualification")
compact_qualification=${qualification_text//[[:space:]]/}
[[ -n $compact_qualification \
    && $compact_qualification[1] == \{ \
    && $compact_qualification[-1] == \} ]] \
    || nogo "qualification contract"
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/spacetrace-release-readiness.XXXXXX") \
    || nogo "qualification contract"
mounted_path=""
cleanup() {
    if [[ -n $mounted_path ]]; then
        hdiutil detach "$mounted_path" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$temporary_root"
}
trap cleanup EXIT INT TERM HUP

qualification_xml="$temporary_root/qualification.xml"
plutil -convert xml1 -o "$qualification_xml" "$qualification" >/dev/null 2>&1 \
    || nogo "qualification contract"

readonly qualification_keys=(
    schemaVersion
    releaseVersion
    sourceCommit
    manifestSha256
    checksumSha256
    licenseIdentifier
    distributionMode
    distributionRiskAccepted
    artifactVerification
    repositoryIntegration
    minimumOSQualification
    currentOSQualification
    cleanAccountGatekeeper
    replacementContinuity
    permissionsAndVolumes
    accessibilityReview
    usabilityResearch
    privacyOfflineReview
    governanceDisposition
    severityReview
    finalReleaseDecision
)

expected_keys=$(printf '%s\n' "${qualification_keys[@]}" | LC_ALL=C /usr/bin/sort)
actual_keys=$(/usr/bin/sed -n \
    's/^[[:space:]]*<key>\([^<]*\)<\/key>[[:space:]]*$/\1/p' \
    "$qualification_xml" | LC_ALL=C /usr/bin/sort)
[[ $actual_keys == $expected_keys ]] || nogo "qualification contract"

for key in "${qualification_keys[@]}"; do
    occurrence_count=$(print -r -- "$qualification_text" \
        | /usr/bin/grep -Eo "\"$key\"[[:space:]]*:" \
        | /usr/bin/wc -l \
        | /usr/bin/tr -d ' ')
    [[ $occurrence_count == 1 ]] || nogo "qualification contract"
done

plist_value() {
    local file=$1
    local key=$2
    local type=$3
    plutil -extract "$key" raw -expect "$type" -o - "$file" 2>/dev/null
}

schema_version=$(plist_value "$qualification" schemaVersion integer) \
    || nogo "qualification contract"
release_version=$(plist_value "$qualification" releaseVersion string) \
    || nogo "qualification contract"
source_commit=$(plist_value "$qualification" sourceCommit string) \
    || nogo "qualification contract"
manifest_sha=$(plist_value "$qualification" manifestSha256 string) \
    || nogo "qualification contract"
checksum_sha=$(plist_value "$qualification" checksumSha256 string) \
    || nogo "qualification contract"
license_identifier=$(plist_value "$qualification" licenseIdentifier string) \
    || nogo "qualification contract"
distribution_mode=$(plist_value "$qualification" distributionMode string) \
    || nogo "qualification contract"
distribution_risk_accepted=$(plist_value \
    "$qualification" distributionRiskAccepted bool) \
    || nogo "qualification contract"

[[ $schema_version == 1 ]] || nogo "qualification contract"
print -r -- "$release_version" | /usr/bin/grep -Eq \
    '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$' \
    || nogo "qualification contract"
print -r -- "$source_commit" | /usr/bin/grep -Eq '^[0-9a-f]{40}$' \
    || nogo "qualification contract"
print -r -- "$manifest_sha" | /usr/bin/grep -Eq '^[0-9a-f]{64}$' \
    || nogo "qualification contract"
print -r -- "$checksum_sha" | /usr/bin/grep -Eq '^[0-9a-f]{64}$' \
    || nogo "qualification contract"

readonly passed_gates=(
    artifactVerification
    repositoryIntegration
    minimumOSQualification
    currentOSQualification
    cleanAccountGatekeeper
    replacementContinuity
    permissionsAndVolumes
    accessibilityReview
    usabilityResearch
    privacyOfflineReview
    governanceDisposition
    severityReview
)
for gate in "${passed_gates[@]}"; do
    gate_value=$(plist_value "$qualification" "$gate" string) \
        || nogo "qualification contract"
    print -r -- "$gate_value" \
        | /usr/bin/grep -Eq '^passed:[0-9a-f]{64}$' \
        || nogo "qualification contract"
done
final_decision=$(plist_value "$qualification" finalReleaseDecision string) \
    || nogo "qualification contract"
print -r -- "$final_decision" \
    | /usr/bin/grep -Eq '^go:[0-9a-f]{64}$' \
    || nogo "qualification contract"

print -r -- "$license_identifier" \
    | /usr/bin/grep -Eq '^[A-Za-z0-9][A-Za-z0-9.+-]{0,63}$' \
    || nogo "license"
[[ $license_identifier != NOASSERTION && $license_identifier != NONE ]] \
    || nogo "license"

[[ $distribution_mode == adhoc-public-beta \
    && $distribution_risk_accepted == true ]] \
    || nogo "distribution"

script_directory=${0:A:h}
repository_root=${script_directory:h}
install_notice_generator="$script_directory/generate-public-beta-install-notice.sh"
readonly approved_license_identifier=PolyForm-Noncommercial-1.0.0
readonly approved_license_sha256=c0ea4a896d2c8c394b29f9427589996db826cd501c512279ff0ed3ef48fabbe5
[[ $license_identifier == $approved_license_identifier ]] || nogo "license"
cd "$repository_root"
[[ -x $install_notice_generator ]] || nogo "artifact contract"
[[ -f LICENSE.md && ! -L LICENSE.md \
    && $(/usr/bin/shasum -a 256 LICENSE.md | /usr/bin/awk '{print $1}') \
        == $approved_license_sha256 ]] || nogo "license"
[[ $(git rev-parse --show-toplevel 2>/dev/null) == $repository_root ]] \
    || nogo "repository integration"
[[ -z $(git status --porcelain=v1 --untracked-files=all 2>/dev/null) ]] \
    || nogo "repository integration"
[[ $(git symbolic-ref --short -q HEAD 2>/dev/null) == main ]] \
    || nogo "repository integration"
head_commit=$(git rev-parse HEAD 2>/dev/null) || nogo "repository integration"
remote_main=$(git rev-parse refs/remotes/origin/main 2>/dev/null) \
    || nogo "repository integration"
[[ $head_commit == $remote_main ]] || nogo "repository integration"
[[ $head_commit == $source_commit ]] || nogo "source binding"

app_name="SpaceTrace-$release_version.app"
dmg_name="SpaceTrace-$release_version.dmg"
manifest_name="SpaceTrace-$release_version.manifest.json"
checksum_name="SpaceTrace-$release_version.sha256"
sbom_name="SpaceTrace-$release_version.spdx.json"
notices_name="SpaceTrace-$release_version.third-party-notices.txt"
readonly expected_entries=(
    "$app_name"
    "$dmg_name"
    "$manifest_name"
    "$checksum_name"
    "$sbom_name"
    "$notices_name"
)
actual_entries=("${(@f)$(/usr/bin/find "$artifacts" -mindepth 1 -maxdepth 1 \
    -exec /usr/bin/basename {} \; 2>/dev/null | LC_ALL=C /usr/bin/sort)}")
expected_entries_sorted=("${(@f)$(printf '%s\n' "${expected_entries[@]}" | LC_ALL=C /usr/bin/sort)}")
[[ "${(j:\n:)actual_entries}" == "${(j:\n:)expected_entries_sorted}" ]] \
    || nogo "artifact contract"

app_path="$artifacts/$app_name"
dmg_path="$artifacts/$dmg_name"
manifest_path="$artifacts/$manifest_name"
checksum_path="$artifacts/$checksum_name"
sbom_path="$artifacts/$sbom_name"
notices_path="$artifacts/$notices_name"
[[ -d $app_path && ! -L $app_path ]] || nogo "artifact contract"
for regular_artifact in \
    "$dmg_path" "$manifest_path" "$checksum_path" "$sbom_path" "$notices_path"; do
    [[ -f $regular_artifact && ! -L $regular_artifact ]] || nogo "artifact contract"
done
[[ $(/usr/bin/stat -f '%z' "$manifest_path" 2>/dev/null) -le 2097152 \
    && $(/usr/bin/stat -f '%z' "$checksum_path" 2>/dev/null) -le 65536 \
    && $(/usr/bin/stat -f '%z' "$sbom_path" 2>/dev/null) -le 2097152 \
    && $(/usr/bin/stat -f '%z' "$notices_path" 2>/dev/null) -le 2097152 \
    && $(/usr/bin/stat -f '%z' "$dmg_path" 2>/dev/null) -le 536870912 ]] \
    || nogo "artifact contract"

actual_manifest_sha=$(/usr/bin/shasum -a 256 "$manifest_path" 2>/dev/null \
    | /usr/bin/awk '{print $1}')
actual_checksum_sha=$(/usr/bin/shasum -a 256 "$checksum_path" 2>/dev/null \
    | /usr/bin/awk '{print $1}')
[[ $actual_manifest_sha == $manifest_sha && $actual_checksum_sha == $checksum_sha ]] \
    || nogo "artifact binding"

[[ $(/usr/bin/wc -l <"$checksum_path" | /usr/bin/tr -d ' ') == 4 ]] \
    || nogo "artifact integrity"
checksum_entries=("${(@f)$(/usr/bin/awk '{print $2}' "$checksum_path" \
    | LC_ALL=C /usr/bin/sort)}")
readonly expected_checksum_entries=(
    "$dmg_name"
    "$manifest_name"
    "$sbom_name"
    "$notices_name"
)
expected_checksum_entries_sorted=("${(@f)$(printf '%s\n' \
    "${expected_checksum_entries[@]}" | LC_ALL=C /usr/bin/sort)}")
[[ "${(j:\n:)checksum_entries}" == "${(j:\n:)expected_checksum_entries_sorted}" ]] \
    || nogo "artifact integrity"
(
    cd "$artifacts"
    /usr/bin/shasum -a 256 -c "$checksum_name" >/dev/null 2>&1
) || nogo "artifact integrity"

manifest_value() {
    local key=$1
    local type=$2
    plutil -extract "$key" raw -expect "$type" -o - "$manifest_path" 2>/dev/null
}

[[ $(manifest_value schemaVersion integer) == 1 \
    && $(manifest_value releaseVersion string) == $release_version \
    && $(manifest_value sourceCommit string) == $source_commit \
    && $(manifest_value sourceTreeClean bool) == true \
    && $(manifest_value minimumSystemVersion string) == 15.6 \
    && $(manifest_value bundleIdentifier string) == com.TREAFREE.SpaceTrace \
    && $(manifest_value architectures array) == 1 \
    && $(manifest_value architectures.0 string) == arm64 \
    && $(manifest_value artifacts.app string) == $app_name \
    && $(manifest_value artifacts.dmg string) == $dmg_name \
    && $(manifest_value artifacts.sbom string) == $sbom_name \
    && $(manifest_value artifacts.thirdPartyNotices string) == $notices_name ]] \
    || nogo "artifact contract"
[[ $(manifest_value artifacts.dmgSha256 string) \
        == $(/usr/bin/shasum -a 256 "$dmg_path" | /usr/bin/awk '{print $1}') \
    && $(manifest_value artifacts.sbomSha256 string) \
        == $(/usr/bin/shasum -a 256 "$sbom_path" | /usr/bin/awk '{print $1}') \
    && $(manifest_value artifacts.thirdPartyNoticesSha256 string) \
        == $(/usr/bin/shasum -a 256 "$notices_path" | /usr/bin/awk '{print $1}') ]] \
    || nogo "artifact integrity"

[[ $(manifest_value signing.mode string) == adhoc \
    && $(manifest_value signing.developerId bool) == false \
    && $(manifest_value signing.hardenedRuntime bool) == true \
    && $(manifest_value signing.notarized bool) == false ]] \
    || nogo "distribution"

[[ $(plutil -extract spdxVersion raw -expect string -o - "$sbom_path" 2>/dev/null) == SPDX-2.3 \
    && $(plutil -extract packages.0.versionInfo raw -expect string -o - "$sbom_path" 2>/dev/null) == $release_version \
    && $(plutil -extract packages.0.licenseDeclared raw -expect string -o - "$sbom_path" 2>/dev/null) == $approved_license_identifier \
    && $(plutil -extract packages.0.licenseConcluded raw -expect string -o - "$sbom_path" 2>/dev/null) == $approved_license_identifier ]] \
    || nogo "license"
/usr/bin/grep -Fxq \
    'Project license: PolyForm Noncommercial License 1.0.0.' \
    "$notices_path" || nogo "license"
/usr/bin/grep -Fxq \
    'https://polyformproject.org/licenses/noncommercial/1.0.0' \
    "$notices_path" || nogo "license"
/usr/bin/grep -Fxq 'Commercial use is not licensed.' "$notices_path" \
    || nogo "license"

codesign --verify --deep --strict --verbose=2 "$app_path" >/dev/null 2>&1 \
    || nogo "artifact integrity"
signature_details=$(codesign -dvvv "$app_path" 2>&1) \
    || nogo "artifact integrity"
[[ $signature_details == *runtime* ]] || nogo "artifact integrity"
[[ $signature_details == *Signature=adhoc* \
    && $signature_details == *"TeamIdentifier=not set"* ]] \
    || nogo "distribution"

info_plist="$app_path/Contents/Info.plist"
executable_path="$app_path/Contents/MacOS/SpaceTrace"
[[ -f $info_plist && -f $executable_path && ! -L $executable_path ]] \
    || nogo "artifact contract"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null) \
        == com.TREAFREE.SpaceTrace \
    && $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info_plist" 2>/dev/null) \
        == 15.6 \
    && $(lipo -archs "$executable_path" 2>/dev/null) == arm64 ]] \
    || nogo "artifact contract"
[[ $(manifest_value artifacts.executableSha256 string) \
        == $(/usr/bin/shasum -a 256 "$executable_path" | /usr/bin/awk '{print $1}') ]] \
    || nogo "artifact integrity"

extracted_entitlements="$temporary_root/entitlements.plist"
codesign -d --entitlements :- "$app_path" >"$extracted_entitlements" 2>/dev/null \
    || nogo "artifact integrity"
for entitlement in \
    com.apple.security.app-sandbox \
    com.apple.security.files.user-selected.read-write \
    com.apple.security.files.bookmarks.app-scope; do
    [[ $(/usr/libexec/PlistBuddy -c "Print :$entitlement" \
        "$extracted_entitlements" 2>/dev/null) == true ]] \
        || nogo "artifact contract"
    /usr/libexec/PlistBuddy -c "Delete :$entitlement" \
        "$extracted_entitlements" >/dev/null 2>&1 \
        || nogo "artifact contract"
done
[[ $(plutil -convert json -o - "$extracted_entitlements" 2>/dev/null) == "{}" ]] \
    || nogo "artifact contract"

embedded_dependency=$(/usr/bin/find "$app_path/Contents" \
    \( -type d -name '*.framework' -o -type f -name '*.dylib' \) \
    -print -quit 2>/dev/null)
[[ -z $embedded_dependency ]] || nogo "artifact contract"
otool -L "$executable_path" >"$temporary_root/dependencies.txt" 2>/dev/null \
    || nogo "artifact integrity"
while IFS= read -r dependency; do
    [[ $dependency == /System/Library/* || $dependency == /usr/lib/* ]] \
        || nogo "artifact contract"
done < <(/usr/bin/awk 'NR > 1 {print $1}' "$temporary_root/dependencies.txt")

hdiutil verify "$dmg_path" >/dev/null 2>&1 || nogo "artifact integrity"
mounted_path="$temporary_root/mounted"
/bin/mkdir "$mounted_path"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mounted_path" "$dmg_path" \
    >/dev/null 2>&1 || nogo "artifact integrity"
mounted_entries=("${(@f)$(/usr/bin/find "$mounted_path" -mindepth 1 -maxdepth 1 \
    -exec /usr/bin/basename {} \; 2>/dev/null | LC_ALL=C /usr/bin/sort)}")
readonly expected_mounted_entries=(
    Applications
    READ-ME-FIRST.txt
    SpaceTrace.app
    THIRD-PARTY-NOTICES.txt
)
[[ "${(j:\n:)mounted_entries}" == "${(j:\n:)expected_mounted_entries}" ]] \
    || nogo "artifact contract"
[[ -L "$mounted_path/Applications" \
    && $(/usr/bin/readlink "$mounted_path/Applications") == /Applications ]] \
    || nogo "artifact contract"
/usr/bin/cmp -s "$notices_path" "$mounted_path/THIRD-PARTY-NOTICES.txt" \
    || nogo "artifact integrity"
expected_install_notice="$temporary_root/expected-install-notice.txt"
"$install_notice_generator" \
    --version "$release_version" \
    --commit "$source_commit" \
    --output "$expected_install_notice" >/dev/null 2>&1 \
    || nogo "artifact contract"
/usr/bin/cmp -s "$expected_install_notice" "$mounted_path/READ-ME-FIRST.txt" \
    || nogo "artifact contract"
codesign --verify --deep --strict --verbose=2 "$mounted_path/SpaceTrace.app" \
    >/dev/null 2>&1 || nogo "artifact integrity"
if : >"$mounted_path/.write-probe" 2>/dev/null; then
    rm -f -- "$mounted_path/.write-probe"
    nogo "artifact contract"
fi
hdiutil detach "$mounted_path" >/dev/null 2>&1 || nogo "artifact integrity"
mounted_path=""

print "release readiness: GO"
