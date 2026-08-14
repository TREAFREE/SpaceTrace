#!/bin/bash

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
qualifier="$repository_root/Scripts/qualify-user-selected-directory.sh"
scratch_root=$(mktemp -d "${TMPDIR:-/tmp}/spacetrace-directory-preflight-contract.XXXXXX")
trap 'rm -rf "$scratch_root"' EXIT INT TERM HUP

readonly version=0.1.0-beta.1
readonly bundle_version=0.1.0
readonly build_version=481
readonly commit=0123456789abcdef0123456789abcdef01234567
readonly bundle_identifier=com.TREAFREE.SpaceTrace

tool_directory="$scratch_root/tools"
app_path="$scratch_root/SpaceTrace-$version.app"
manifest_path="$scratch_root/SpaceTrace-$version.manifest.json"
entitlements_path="$scratch_root/entitlements.plist"
report_path="$scratch_root/preflight.json"
mkdir -p "$tool_directory" "$app_path/Contents/MacOS"

cat >"$app_path/Contents/MacOS/SpaceTrace" <<'EXECUTABLE'
#!/bin/sh
exit 0
EXECUTABLE
chmod 755 "$app_path/Contents/MacOS/SpaceTrace"

info_plist="$app_path/Contents/Info.plist"
plutil -create xml1 "$info_plist"
plutil -insert CFBundleIdentifier -string "$bundle_identifier" "$info_plist"
plutil -insert CFBundleExecutable -string SpaceTrace "$info_plist"
plutil -insert CFBundleShortVersionString -string "$bundle_version" "$info_plist"
plutil -insert CFBundleVersion -string "$build_version" "$info_plist"
plutil -insert LSMinimumSystemVersion -string 15.6 "$info_plist"

plutil -create xml1 "$entitlements_path"
/usr/libexec/PlistBuddy -c \
    'Add :com.apple.security.app-sandbox bool true' "$entitlements_path"
/usr/libexec/PlistBuddy -c \
    'Add :com.apple.security.files.user-selected.read-write bool true' "$entitlements_path"
/usr/libexec/PlistBuddy -c \
    'Add :com.apple.security.files.bookmarks.app-scope bool true' "$entitlements_path"

cat >"$tool_directory/sw_vers" <<'TOOL'
#!/bin/sh
case "$1" in
    -productVersion) printf '%s\n' "${SPACETRACE_TEST_PRODUCT_VERSION:-15.6}" ;;
    -buildVersion) printf '%s\n' "${SPACETRACE_TEST_BUILD_VERSION:-24G90}" ;;
    *) exit 64 ;;
esac
TOOL
cat >"$tool_directory/uname" <<'TOOL'
#!/bin/sh
[[ $1 == -m ]] || exit 64
printf '%s\n' "${SPACETRACE_TEST_ARCHITECTURE:-arm64}"
TOOL
cat >"$tool_directory/lipo" <<'TOOL'
#!/bin/sh
[[ $1 == -archs ]] || exit 64
printf '%s\n' "${SPACETRACE_TEST_APP_ARCHITECTURES:-arm64}"
TOOL
cat >"$tool_directory/codesign" <<'TOOL'
#!/bin/sh
if [[ ${1:-} == --verify ]]; then
    exit "${SPACETRACE_TEST_CODESIGN_VERIFY_STATUS:-0}"
fi
if [[ ${1:-} == -dvvv ]]; then
    if [[ -n ${SPACETRACE_TEST_SIGNATURE_DETAILS:-} ]]; then
        printf '%s\n' "$SPACETRACE_TEST_SIGNATURE_DETAILS" >&2
    else
        printf '%s\n' \
            'Signature=adhoc' \
            'TeamIdentifier=not set' \
            'CodeDirectory flags=0x10000(runtime)' >&2
    fi
    exit 0
fi
if [[ ${1:-} == -d && ${2:-} == --entitlements ]]; then
    cat "$SPACETRACE_TEST_ENTITLEMENTS"
    exit 0
fi
exit 64
TOOL
chmod 755 "$tool_directory/sw_vers" "$tool_directory/uname" \
    "$tool_directory/lipo" "$tool_directory/codesign"

executable_sha=$(shasum -a 256 "$app_path/Contents/MacOS/SpaceTrace" | awk '{print $1}')
manifest_plist="$scratch_root/manifest.plist"
plutil -create xml1 "$manifest_plist"
plutil -insert schemaVersion -integer 1 "$manifest_plist"
plutil -insert releaseVersion -string "$version" "$manifest_plist"
plutil -insert bundleVersion -string "$bundle_version" "$manifest_plist"
plutil -insert buildVersion -string "$build_version" "$manifest_plist"
plutil -insert bundleIdentifier -string "$bundle_identifier" "$manifest_plist"
plutil -insert sourceCommit -string "$commit" "$manifest_plist"
plutil -insert sourceTreeClean -bool true "$manifest_plist"
plutil -insert minimumSystemVersion -string 15.6 "$manifest_plist"
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
plutil -insert artifacts.app -string "SpaceTrace-$version.app" "$manifest_plist"
plutil -insert artifacts.dmg -string "SpaceTrace-$version.dmg" "$manifest_plist"
plutil -insert artifacts.dmgSha256 -string "$(printf 'a%.0s' {1..64})" "$manifest_plist"
plutil -insert artifacts.executableSha256 -string "$executable_sha" "$manifest_plist"
plutil -insert artifacts.sbom -string "SpaceTrace-$version.spdx.json" "$manifest_plist"
plutil -insert artifacts.sbomSha256 -string "$(printf 'b%.0s' {1..64})" "$manifest_plist"
plutil -insert artifacts.thirdPartyNotices -string "SpaceTrace-$version.third-party-notices.txt" "$manifest_plist"
plutil -insert artifacts.thirdPartyNoticesSha256 -string "$(printf 'c%.0s' {1..64})" "$manifest_plist"
plutil -insert buildEnvironment -dictionary "$manifest_plist"
plutil -insert buildEnvironment.hostOS -string 26.5.2 "$manifest_plist"
plutil -insert buildEnvironment.xcode -string 'Xcode 26.1.1 Build version 17B100' "$manifest_plist"
plutil -insert reproducibility -string \
    'source-and-contract reproducible; compressed DMG bytes are not claimed bit-for-bit deterministic' \
    "$manifest_plist"
plutil -convert json -o "$manifest_path" "$manifest_plist"

expect_failure() {
    local label=$1
    local expected_status=$2
    local expected_message=$3
    shift 3
    local stdout_file="$scratch_root/$label.stdout"
    local stderr_file="$scratch_root/$label.stderr"
    local status=0

    "$@" >"$stdout_file" 2>"$stderr_file" || status=$?
    if [[ $status -ne $expected_status ]]; then
        printf 'FAIL: %s exited %s instead of %s\n' \
            "$label" "$status" "$expected_status" >&2
        cat "$stdout_file" "$stderr_file" >&2
        exit 1
    fi
    if ! grep -Fq "$expected_message" "$stdout_file" "$stderr_file"; then
        printf 'FAIL: %s did not report %s\n' "$label" "$expected_message" >&2
        cat "$stdout_file" "$stderr_file" >&2
        exit 1
    fi
    if grep -Fq "$scratch_root" "$stdout_file" "$stderr_file"; then
        printf 'FAIL: %s leaked an input path\n' "$label" >&2
        exit 1
    fi
}

base_environment=(
    PATH="$tool_directory:/usr/bin:/bin:/usr/sbin:/sbin"
    SPACETRACE_TEST_ENTITLEMENTS="$entitlements_path"
)

primary_status=0
PATH="$tool_directory:/usr/bin:/bin:/usr/sbin:/sbin" \
SPACETRACE_TEST_ENTITLEMENTS="$entitlements_path" \
    "$qualifier" \
    --app "$app_path" \
    --manifest "$manifest_path" \
    --distribution-mode adhoc-public-beta \
    --accept-risk \
    --output "$report_path" \
    >"$scratch_root/stdout" 2>"$scratch_root/stderr" || primary_status=$?
if [[ $primary_status -ne 0 ]]; then
    printf 'FAIL: valid 15.6 ad-hoc preflight exited %s\n' "$primary_status" >&2
    cat "$scratch_root/stdout" "$scratch_root/stderr" >&2
    exit 1
fi

grep -Fxq 'user-selected directory preflight: PASS' "$scratch_root/stdout"
[[ ! -s $scratch_root/stderr ]]
[[ $(plutil -extract schemaVersion raw -expect integer -o - "$report_path") == 1 ]]
[[ $(plutil -extract status raw -expect string -o - "$report_path") == passed ]]
[[ $(plutil -extract distributionMode raw -expect string -o - "$report_path") == adhoc-public-beta ]]
[[ $(plutil -extract distributionRiskAccepted raw -expect bool -o - "$report_path") == true ]]
[[ $(plutil -extract hostProductVersion raw -expect string -o - "$report_path") == 15.6 ]]
[[ $(plutil -extract releaseVersion raw -expect string -o - "$report_path") == "$version" ]]
[[ $(plutil -extract sourceCommit raw -expect string -o - "$report_path") == "$commit" ]]
[[ $(plutil -extract executableSha256 raw -expect string -o - "$report_path") == "$executable_sha" ]]
[[ $(plutil -extract signatureMode raw -expect string -o - "$report_path") == adhoc ]]
[[ $(plutil -extract hardenedRuntime raw -expect bool -o - "$report_path") == true ]]
[[ $(stat -f '%Lp' "$report_path") == 600 ]]
[[ $(stat -f '%z' "$report_path") -le 16384 ]]
[[ $(plutil -extract entitlements json -o - "$report_path") \
    == '["com.apple.security.app-sandbox","com.apple.security.files.user-selected.read-write","com.apple.security.files.bookmarks.app-scope"]' ]]

expected_report_keys=$(printf '%s\n' \
    schemaVersion qualificationType status releaseVersion sourceCommit \
    manifestSha256 executableSha256 distributionMode distributionRiskAccepted \
    hostProductVersion hostBuildVersion hostArchitecture bundleIdentifier \
    bundleVersion buildVersion minimumSystemVersion signatureMode teamIdentifier \
    hardenedRuntime entitlements qualificationScope manualMatrix | LC_ALL=C sort)
actual_report_keys=$(plutil -convert xml1 -o - "$report_path" \
    | sed -n 's/^[[:space:]]*<key>\([^<]*\)<\/key>$/\1/p' \
    | LC_ALL=C sort)
[[ $actual_report_keys == "$expected_report_keys" ]]

if grep -Fq "$scratch_root" "$scratch_root/stdout" \
    || grep -Fq "$scratch_root" "$scratch_root/stderr" \
    || grep -Fq "$scratch_root" "$report_path"; then
    printf 'FAIL: preflight evidence leaked a local path\n' >&2
    exit 1
fi

expect_failure missing-arguments 64 'usage:' "$qualifier"
expect_failure missing-risk 64 'usage:' \
    /usr/bin/env "${base_environment[@]}" "$qualifier" \
    --app "$app_path" --manifest "$manifest_path" \
    --distribution-mode adhoc-public-beta \
    --output "$scratch_root/missing-risk.json"
expect_failure unsupported-distribution 64 \
    'user-selected directory preflight: NO-GO (distribution contract)' \
    /usr/bin/env "${base_environment[@]}" "$qualifier" \
    --app "$app_path" --manifest "$manifest_path" \
    --distribution-mode developer-id-stable --accept-risk \
    --output "$scratch_root/unsupported-mode.json"

expect_failure newer-host-without-smoke 2 \
    'user-selected directory preflight: NO-GO (minimum OS contract)' \
    /usr/bin/env "${base_environment[@]}" \
    SPACETRACE_TEST_PRODUCT_VERSION=26.5.2 "$qualifier" \
    --app "$app_path" --manifest "$manifest_path" \
    --distribution-mode adhoc-public-beta --accept-risk \
    --output "$scratch_root/newer-rejected.json"
[[ ! -e $scratch_root/newer-rejected.json ]]

smoke_report="$scratch_root/smoke.json"
/usr/bin/env "${base_environment[@]}" \
    SPACETRACE_TEST_PRODUCT_VERSION=26.5.2 "$qualifier" \
    --app "$app_path" --manifest "$manifest_path" \
    --distribution-mode adhoc-public-beta --accept-risk \
    --allow-newer-host-smoke --output "$smoke_report" \
    >"$scratch_root/smoke.stdout" 2>"$scratch_root/smoke.stderr"
grep -Fxq 'user-selected directory preflight: SMOKE' "$scratch_root/smoke.stdout"
grep -Fxq \
    'qualification boundary: newer host does not qualify macOS 15.6' \
    "$scratch_root/smoke.stdout"
if grep -Fq 'PASS' "$scratch_root/smoke.stdout" \
    || [[ $(plutil -extract status raw -expect string -o - "$smoke_report") != smoke ]]; then
    printf 'FAIL: newer-host smoke was presented as qualification\n' >&2
    exit 1
fi

expect_failure older-host 2 \
    'user-selected directory preflight: NO-GO (minimum OS contract)' \
    /usr/bin/env "${base_environment[@]}" \
    SPACETRACE_TEST_PRODUCT_VERSION=15.5.9 "$qualifier" \
    --app "$app_path" --manifest "$manifest_path" \
    --distribution-mode adhoc-public-beta --accept-risk \
    --allow-newer-host-smoke --output "$scratch_root/older.json"
expect_failure wrong-host-architecture 2 \
    'user-selected directory preflight: NO-GO (host contract)' \
    /usr/bin/env "${base_environment[@]}" \
    SPACETRACE_TEST_ARCHITECTURE=x86_64 "$qualifier" \
    --app "$app_path" --manifest "$manifest_path" \
    --distribution-mode adhoc-public-beta --accept-risk \
    --output "$scratch_root/x86.json"

existing_output="$scratch_root/existing.json"
printf 'sentinel\n' >"$existing_output"
expect_failure existing-output 64 \
    'user-selected directory preflight: NO-GO (output contract)' \
    /usr/bin/env "${base_environment[@]}" "$qualifier" \
    --app "$app_path" --manifest "$manifest_path" \
    --distribution-mode adhoc-public-beta --accept-risk \
    --output "$existing_output"
[[ $(<"$existing_output") == sentinel ]]

manifest_link="$scratch_root/manifest-link.json"
ln -s "$manifest_path" "$manifest_link"
expect_failure symlink-manifest 64 \
    'user-selected directory preflight: NO-GO (manifest contract)' \
    /usr/bin/env "${base_environment[@]}" "$qualifier" \
    --app "$app_path" --manifest "$manifest_link" \
    --distribution-mode adhoc-public-beta --accept-risk \
    --output "$scratch_root/symlink-manifest-report.json"

expect_failure invalid-signature 2 \
    'user-selected directory preflight: NO-GO (signature contract)' \
    /usr/bin/env "${base_environment[@]}" \
    SPACETRACE_TEST_CODESIGN_VERIFY_STATUS=1 "$qualifier" \
    --app "$app_path" --manifest "$manifest_path" \
    --distribution-mode adhoc-public-beta --accept-risk \
    --output "$scratch_root/invalid-signature.json"

extra_entitlements="$scratch_root/extra-entitlements.plist"
cp "$entitlements_path" "$extra_entitlements"
/usr/libexec/PlistBuddy -c \
    'Add :com.apple.security.network.client bool true' "$extra_entitlements"
expect_failure extra-entitlement 2 \
    'user-selected directory preflight: NO-GO (entitlement contract)' \
    /usr/bin/env PATH="$tool_directory:/usr/bin:/bin:/usr/sbin:/sbin" \
    SPACETRACE_TEST_ENTITLEMENTS="$extra_entitlements" "$qualifier" \
    --app "$app_path" --manifest "$manifest_path" \
    --distribution-mode adhoc-public-beta --accept-risk \
    --output "$scratch_root/extra-entitlement.json"

dirty_manifest="$scratch_root/dirty.manifest.json"
cp "$manifest_path" "$dirty_manifest"
plutil -replace sourceTreeClean -bool false "$dirty_manifest"
expect_failure dirty-source-manifest 2 \
    'user-selected directory preflight: NO-GO (manifest contract)' \
    /usr/bin/env "${base_environment[@]}" "$qualifier" \
    --app "$app_path" --manifest "$dirty_manifest" \
    --distribution-mode adhoc-public-beta --accept-risk \
    --output "$scratch_root/dirty-source.json"

bad_hash_manifest="$scratch_root/bad-hash.manifest.json"
cp "$manifest_path" "$bad_hash_manifest"
plutil -replace artifacts.executableSha256 -string \
    "$(printf 'f%.0s' {1..64})" "$bad_hash_manifest"
expect_failure executable-hash-mismatch 2 \
    'user-selected directory preflight: NO-GO (app binding contract)' \
    /usr/bin/env "${base_environment[@]}" "$qualifier" \
    --app "$app_path" --manifest "$bad_hash_manifest" \
    --distribution-mode adhoc-public-beta --accept-risk \
    --output "$scratch_root/bad-hash.json"

tampered_app_root="$scratch_root/tampered-app"
mkdir "$tampered_app_root"
cp -R "$app_path" "$tampered_app_root/SpaceTrace-$version.app"
printf '# tampered\n' >>"$tampered_app_root/SpaceTrace-$version.app/Contents/MacOS/SpaceTrace"
expect_failure tampered-executable 2 \
    'user-selected directory preflight: NO-GO (app binding contract)' \
    /usr/bin/env "${base_environment[@]}" "$qualifier" \
    --app "$tampered_app_root/SpaceTrace-$version.app" \
    --manifest "$manifest_path" \
    --distribution-mode adhoc-public-beta --accept-risk \
    --output "$scratch_root/tampered-executable.json"

metadata_app_root="$scratch_root/metadata-app"
mkdir "$metadata_app_root"
cp -R "$app_path" "$metadata_app_root/SpaceTrace-$version.app"
plutil -replace LSMinimumSystemVersion -string 15.5 \
    "$metadata_app_root/SpaceTrace-$version.app/Contents/Info.plist"
expect_failure app-metadata-mismatch 2 \
    'user-selected directory preflight: NO-GO (app binding contract)' \
    /usr/bin/env "${base_environment[@]}" "$qualifier" \
    --app "$metadata_app_root/SpaceTrace-$version.app" \
    --manifest "$manifest_path" \
    --distribution-mode adhoc-public-beta --accept-risk \
    --output "$scratch_root/app-metadata.json"

executable_name_app_root="$scratch_root/executable-name-app"
mkdir "$executable_name_app_root"
cp -R "$app_path" "$executable_name_app_root/SpaceTrace-$version.app"
plutil -replace CFBundleExecutable -string OtherExecutable \
    "$executable_name_app_root/SpaceTrace-$version.app/Contents/Info.plist"
expect_failure app-executable-name-mismatch 2 \
    'user-selected directory preflight: NO-GO (app binding contract)' \
    /usr/bin/env "${base_environment[@]}" "$qualifier" \
    --app "$executable_name_app_root/SpaceTrace-$version.app" \
    --manifest "$manifest_path" \
    --distribution-mode adhoc-public-beta --accept-risk \
    --output "$scratch_root/app-executable-name.json"

missing_entitlements="$scratch_root/missing-entitlements.plist"
cp "$entitlements_path" "$missing_entitlements"
/usr/libexec/PlistBuddy -c \
    'Delete :com.apple.security.files.bookmarks.app-scope' "$missing_entitlements"
expect_failure missing-entitlement 2 \
    'user-selected directory preflight: NO-GO (entitlement contract)' \
    /usr/bin/env PATH="$tool_directory:/usr/bin:/bin:/usr/sbin:/sbin" \
    SPACETRACE_TEST_ENTITLEMENTS="$missing_entitlements" "$qualifier" \
    --app "$app_path" --manifest "$manifest_path" \
    --distribution-mode adhoc-public-beta --accept-risk \
    --output "$scratch_root/missing-entitlement.json"

malformed_manifest="$scratch_root/malformed.manifest.json"
printf '{"schemaVersion":1' >"$malformed_manifest"
expect_failure malformed-manifest 2 \
    'user-selected directory preflight: NO-GO (manifest contract)' \
    /usr/bin/env "${base_environment[@]}" "$qualifier" \
    --app "$app_path" --manifest "$malformed_manifest" \
    --distribution-mode adhoc-public-beta --accept-risk \
    --output "$scratch_root/malformed-report.json"

duplicate_manifest="$scratch_root/duplicate.manifest.json"
sed 's/"schemaVersion":1/"schemaVersion":1,"schemaVersion":1/' \
    "$manifest_path" >"$duplicate_manifest"
expect_failure duplicate-manifest-key 2 \
    'user-selected directory preflight: NO-GO (manifest contract)' \
    /usr/bin/env "${base_environment[@]}" "$qualifier" \
    --app "$app_path" --manifest "$duplicate_manifest" \
    --distribution-mode adhoc-public-beta --accept-risk \
    --output "$scratch_root/duplicate-report.json"

app_link="$scratch_root/SpaceTrace-link.app"
ln -s "$app_path" "$app_link"
expect_failure symlink-app 64 \
    'user-selected directory preflight: NO-GO (app contract)' \
    /usr/bin/env "${base_environment[@]}" "$qualifier" \
    --app "$app_link" --manifest "$manifest_path" \
    --distribution-mode adhoc-public-beta --accept-risk \
    --output "$scratch_root/symlink-app-report.json"

legacy_stdout="$scratch_root/legacy.stdout"
legacy_stderr="$scratch_root/legacy.stderr"
legacy_status=0
SPACETRACE_ALLOW_NEWER_HOST_SMOKE=1 \
SPACETRACE_ALLOW_ADHOC_SMOKE=1 \
    "$qualifier" "$app_path" >"$legacy_stdout" 2>"$legacy_stderr" \
    || legacy_status=$?
if [[ $legacy_status -ne 64 ]] || grep -Fq 'PASS' "$legacy_stdout"; then
    printf 'FAIL: legacy environment overrides still authorize qualification\n' >&2
    exit 1
fi

unknown_manifest="$scratch_root/unknown.manifest.json"
cp "$manifest_path" "$unknown_manifest"
plutil -insert futureField -string forbidden "$unknown_manifest"
if PATH="$tool_directory:/usr/bin:/bin:/usr/sbin:/sbin" \
    SPACETRACE_TEST_ENTITLEMENTS="$entitlements_path" \
        "$qualifier" \
        --app "$app_path" \
        --manifest "$unknown_manifest" \
        --distribution-mode adhoc-public-beta \
        --accept-risk \
        --output "$scratch_root/unknown-report.json" \
        >"$scratch_root/unknown.stdout" 2>"$scratch_root/unknown.stderr"; then
    printf 'RED: unknown manifest field was accepted\n' >&2
    exit 1
fi

contradictory_signature=$'Signature=adhoc\nTeamIdentifier=TEAM123\nnote=TeamIdentifier=not set\nflags=0x10000(runtime)'
if PATH="$tool_directory:/usr/bin:/bin:/usr/sbin:/sbin" \
    SPACETRACE_TEST_ENTITLEMENTS="$entitlements_path" \
    SPACETRACE_TEST_SIGNATURE_DETAILS="$contradictory_signature" \
        "$qualifier" \
        --app "$app_path" \
        --manifest "$manifest_path" \
        --distribution-mode adhoc-public-beta \
        --accept-risk \
        --output "$scratch_root/contradictory-signature.json" \
        >"$scratch_root/contradictory.stdout" \
        2>"$scratch_root/contradictory.stderr"; then
    printf 'RED: contradictory TeamIdentifier was accepted\n' >&2
    exit 1
fi

misleading_runtime=$'Signature=adhoc\nTeamIdentifier=not set\nCodeDirectory flags=0x0(none) note=runtime'
if PATH="$tool_directory:/usr/bin:/bin:/usr/sbin:/sbin" \
    SPACETRACE_TEST_ENTITLEMENTS="$entitlements_path" \
    SPACETRACE_TEST_SIGNATURE_DETAILS="$misleading_runtime" \
        "$qualifier" \
        --app "$app_path" \
        --manifest "$manifest_path" \
        --distribution-mode adhoc-public-beta \
        --accept-risk \
        --output "$scratch_root/misleading-runtime.json" \
        >"$scratch_root/runtime.stdout" 2>"$scratch_root/runtime.stderr"; then
    printf 'RED: misleading Hardened Runtime text was accepted\n' >&2
    exit 1
fi

make_zero_output=$(make -C "$repository_root" -n qualify-user-selected-directory \
    APP=/Applications/SpaceTrace.app \
    MANIFEST=/private/tmp/SpaceTrace.manifest.json \
    REPORT=/private/tmp/SpaceTrace.preflight.json \
    ALLOW_NEWER_HOST_SMOKE=0)
if grep -Fq -- '--allow-newer-host-smoke' <<<"$make_zero_output"; then
    printf 'FAIL: Make value 0 enabled the newer-host smoke escape hatch\n' >&2
    exit 1
fi

make_one_output=$(make -C "$repository_root" -n qualify-user-selected-directory \
    APP=/Applications/SpaceTrace.app \
    MANIFEST=/private/tmp/SpaceTrace.manifest.json \
    REPORT=/private/tmp/SpaceTrace.preflight.json \
    ALLOW_NEWER_HOST_SMOKE=1)
if [[ $(grep -Fc -- '--allow-newer-host-smoke' <<<"$make_one_output") -ne 1 ]]; then
    printf 'FAIL: Make value 1 did not enable exactly one smoke flag\n' >&2
    exit 1
fi

printf 'user-selected directory preflight contract: PASS\n'
