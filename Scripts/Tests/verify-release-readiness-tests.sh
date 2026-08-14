#!/bin/bash

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
production_script="$repository_root/Scripts/verify-release-readiness.sh"
install_notice_generator="$repository_root/Scripts/generate-public-beta-install-notice.sh"

if [[ ! -x "$production_script" || ! -x "$install_notice_generator" ]]; then
    printf 'RED: production release-readiness dependency is missing\n' >&2
    exit 1
fi

scratch_root=$(mktemp -d "${TMPDIR:-/tmp}/spacetrace-release-readiness-contract.XXXXXX")
trap 'rm -rf "$scratch_root"' EXIT

passed_cases=0
failed_cases=0
readonly expected_cases=24
readonly approved_license=PolyForm-Noncommercial-1.0.0

pass_case() {
    passed_cases=$((passed_cases + 1))
}

fail_case() {
    printf 'FAIL: %s\n' "$1" >&2
    failed_cases=$((failed_cases + 1))
}

expect_result() {
    local label=$1
    local expected_status=$2
    local expected_message=$3
    local qualification=$4
    local artifacts=$5
    local output="$scratch_root/$label.output"
    local status=0

    "$fixture_repository/Scripts/verify-release-readiness.sh" \
        --qualification "$qualification" \
        --artifacts "$artifacts" >"$output" 2>&1 || status=$?

    if [[ $status -ne $expected_status ]]; then
        local actual_result
        actual_result=$(grep -E '^(release readiness:|usage:)' "$output" | tail -1 || true)
        fail_case "$label returned $status, expected $expected_status; result=${actual_result:-missing}"
        return
    fi
    if ! grep -Fxq "$expected_message" "$output"; then
        local actual_result
        actual_result=$(grep -E '^(release readiness:|usage:)' "$output" | tail -1 || true)
        fail_case "$label did not emit its canonical result; result=${actual_result:-missing}"
        return
    fi
    local local_path_pattern='/''Users/|/private/|/tmp/'
    if grep -Eq "$local_path_pattern" "$output"; then
        fail_case "$label disclosed a local path"
        return
    fi
    pass_case
}

create_fixture_repository() {
    fixture_repository="$scratch_root/repository"
    mkdir -p "$fixture_repository/Scripts"
    cp "$production_script" "$fixture_repository/Scripts/verify-release-readiness.sh"
    cp "$install_notice_generator" \
        "$fixture_repository/Scripts/generate-public-beta-install-notice.sh"
    cp "$repository_root/LICENSE.md" "$fixture_repository/LICENSE.md"
    chmod +x \
        "$fixture_repository/Scripts/verify-release-readiness.sh" \
        "$fixture_repository/Scripts/generate-public-beta-install-notice.sh"
    printf 'Synthetic SpaceTrace release-readiness fixture.\n' >"$fixture_repository/README.md"

    git -C "$fixture_repository" init -q -b main
    git -C "$fixture_repository" config user.name "SpaceTrace Tests"
    git -C "$fixture_repository" config user.email "tests@example.invalid"
    git -C "$fixture_repository" add README.md
    git -C "$fixture_repository" commit -q -m base
    git -C "$fixture_repository" add \
        Scripts/verify-release-readiness.sh \
        Scripts/generate-public-beta-install-notice.sh \
        LICENSE.md
    git -C "$fixture_repository" commit -q -m verifier
    fixture_commit=$(git -C "$fixture_repository" rev-parse HEAD)
    git -C "$fixture_repository" update-ref refs/remotes/origin/main "$fixture_commit"
}

create_artifacts() {
    version=0.1.0-beta.1
    canonical_artifacts="$scratch_root/canonical-artifacts"
    local app="$canonical_artifacts/SpaceTrace-$version.app"
    local executable="$app/Contents/MacOS/SpaceTrace"
    local dmg="$canonical_artifacts/SpaceTrace-$version.dmg"
    local manifest="$canonical_artifacts/SpaceTrace-$version.manifest.json"
    local checksum="$canonical_artifacts/SpaceTrace-$version.sha256"
    local sbom="$canonical_artifacts/SpaceTrace-$version.spdx.json"
    local notices="$canonical_artifacts/SpaceTrace-$version.third-party-notices.txt"
    local dmg_root="$scratch_root/dmg-root"
    local source="$scratch_root/main.c"
    local entitlements="$scratch_root/entitlements.plist"

    mkdir -p "$app/Contents/MacOS" "$dmg_root"
    cat >"$source" <<'EOF'
int main(void) { return 0; }
EOF
    xcrun clang -arch arm64 -mmacosx-version-min=15.6 "$source" -o "$executable"
    cat >"$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SpaceTrace</string>
<key>CFBundleIdentifier</key><string>com.TREAFREE.SpaceTrace</string>
<key>CFBundleName</key><string>SpaceTrace</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.6</string>
</dict></plist>
EOF
    cat >"$entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.files.bookmarks.app-scope</key><true/>
</dict></plist>
EOF
    codesign --force --deep --sign - --timestamp=none --options runtime \
        --entitlements "$entitlements" "$app" >/dev/null 2>&1

    printf '%s\n' \
        'Project license: PolyForm Noncommercial License 1.0.0.' \
        'https://polyformproject.org/licenses/noncommercial/1.0.0' \
        'Commercial use is not licensed.' \
        >"$notices"
    cat >"$sbom" <<EOF
{"spdxVersion":"SPDX-2.3","dataLicense":"CC0-1.0","packages":[{"name":"SpaceTrace","versionInfo":"$version","licenseDeclared":"$approved_license","licenseConcluded":"$approved_license","filesAnalyzed":false,"downloadLocation":"https://github.com/TREAFREE/SpaceTrace/tree/$fixture_commit"}]}
EOF

    ditto "$app" "$dmg_root/SpaceTrace.app"
    ln -s /Applications "$dmg_root/Applications"
    cp "$notices" "$dmg_root/THIRD-PARTY-NOTICES.txt"
    "$fixture_repository/Scripts/generate-public-beta-install-notice.sh" \
        --version "$version" \
        --commit "$fixture_commit" \
        --output "$dmg_root/READ-ME-FIRST.txt"
    hdiutil create -quiet -fs HFS+ -format UDZO -volname "SpaceTrace RC $version" \
        -srcfolder "$dmg_root" "$dmg"

    local dmg_sha executable_sha sbom_sha notices_sha
    dmg_sha=$(shasum -a 256 "$dmg" | awk '{print $1}')
    executable_sha=$(shasum -a 256 "$executable" | awk '{print $1}')
    sbom_sha=$(shasum -a 256 "$sbom" | awk '{print $1}')
    notices_sha=$(shasum -a 256 "$notices" | awk '{print $1}')
    cat >"$manifest" <<EOF
{"schemaVersion":1,"releaseVersion":"$version","bundleVersion":"0.1.0","buildVersion":"1","bundleIdentifier":"com.TREAFREE.SpaceTrace","sourceCommit":"$fixture_commit","sourceTreeClean":true,"minimumSystemVersion":"15.6","architectures":["arm64"],"entitlements":["com.apple.security.app-sandbox","com.apple.security.files.bookmarks.app-scope","com.apple.security.files.user-selected.read-write"],"signing":{"mode":"adhoc","developerId":false,"hardenedRuntime":true,"notarized":false},"gatekeeperAssessment":"expected-rejected-unnotarized","artifacts":{"app":"SpaceTrace-$version.app","dmg":"SpaceTrace-$version.dmg","dmgSha256":"$dmg_sha","executableSha256":"$executable_sha","sbom":"SpaceTrace-$version.spdx.json","sbomSha256":"$sbom_sha","thirdPartyNotices":"SpaceTrace-$version.third-party-notices.txt","thirdPartyNoticesSha256":"$notices_sha"}}
EOF
    (
        cd "$canonical_artifacts"
        shasum -a 256 \
            "SpaceTrace-$version.dmg" \
            "SpaceTrace-$version.manifest.json" \
            "SpaceTrace-$version.spdx.json" \
            "SpaceTrace-$version.third-party-notices.txt" \
            >"SpaceTrace-$version.sha256"
    )
}

create_qualification() {
    local destination=$1
    local manifest_sha checksum_sha
    manifest_sha=$(shasum -a 256 "$canonical_artifacts/SpaceTrace-$version.manifest.json" | awk '{print $1}')
    checksum_sha=$(shasum -a 256 "$canonical_artifacts/SpaceTrace-$version.sha256" | awk '{print $1}')
    cat >"$destination" <<EOF
{"schemaVersion":1,"releaseVersion":"$version","sourceCommit":"$fixture_commit","manifestSha256":"$manifest_sha","checksumSha256":"$checksum_sha","licenseIdentifier":"$approved_license","distributionMode":"adhoc-public-beta","distributionRiskAccepted":true,"artifactVerification":"passed:0000000000000000000000000000000000000000000000000000000000000001","repositoryIntegration":"passed:0000000000000000000000000000000000000000000000000000000000000002","minimumOSQualification":"passed:0000000000000000000000000000000000000000000000000000000000000003","currentOSQualification":"passed:0000000000000000000000000000000000000000000000000000000000000004","cleanAccountGatekeeper":"passed:0000000000000000000000000000000000000000000000000000000000000005","replacementContinuity":"passed:0000000000000000000000000000000000000000000000000000000000000006","permissionsAndVolumes":"passed:0000000000000000000000000000000000000000000000000000000000000007","accessibilityReview":"passed:0000000000000000000000000000000000000000000000000000000000000008","usabilityResearch":"passed:0000000000000000000000000000000000000000000000000000000000000009","privacyOfflineReview":"passed:000000000000000000000000000000000000000000000000000000000000000a","governanceDisposition":"passed:000000000000000000000000000000000000000000000000000000000000000b","severityReview":"passed:000000000000000000000000000000000000000000000000000000000000000c","finalReleaseDecision":"go:000000000000000000000000000000000000000000000000000000000000000d"}
EOF
}

rebind_case_hashes() {
    local manifest="$case_artifacts/SpaceTrace-$version.manifest.json"
    local checksum="$case_artifacts/SpaceTrace-$version.sha256"
    local sbom="$case_artifacts/SpaceTrace-$version.spdx.json"
    local sbom_sha manifest_sha checksum_sha

    sbom_sha=$(shasum -a 256 "$sbom" | awk '{print $1}')
    plutil -replace artifacts.sbomSha256 -string "$sbom_sha" "$manifest"
    (
        cd "$case_artifacts"
        shasum -a 256 \
            "SpaceTrace-$version.dmg" \
            "SpaceTrace-$version.manifest.json" \
            "SpaceTrace-$version.spdx.json" \
            "SpaceTrace-$version.third-party-notices.txt" \
            >"SpaceTrace-$version.sha256"
    )
    manifest_sha=$(shasum -a 256 "$manifest" | awk '{print $1}')
    checksum_sha=$(shasum -a 256 "$checksum" | awk '{print $1}')
    plutil -replace manifestSha256 -string "$manifest_sha" "$case_qualification"
    plutil -replace checksumSha256 -string "$checksum_sha" "$case_qualification"
}

copy_case() {
    local label=$1
    case_artifacts="$scratch_root/$label-artifacts"
    case_qualification="$scratch_root/$label-qualification.json"
    ditto "$canonical_artifacts" "$case_artifacts"
    cp "$canonical_qualification" "$case_qualification"
}

create_fixture_repository
create_artifacts
canonical_qualification="$scratch_root/canonical-qualification.json"
create_qualification "$canonical_qualification"

usage_output="$scratch_root/usage.output"
usage_status=0
"$fixture_repository/Scripts/verify-release-readiness.sh" >"$usage_output" 2>&1 || usage_status=$?
if [[ $usage_status -eq 64 ]] && grep -Fq 'usage:' "$usage_output"; then
    pass_case
else
    fail_case "missing arguments did not return usage status 64"
fi

copy_case valid
expect_result valid 0 'release readiness: GO' "$case_qualification" "$case_artifacts"

copy_case missing-gate
plutil -remove minimumOSQualification "$case_qualification"
expect_result missing-gate 1 'release readiness: NO-GO (qualification contract)' "$case_qualification" "$case_artifacts"

copy_case unknown-field
plutil -insert future -string unsafe "$case_qualification"
expect_result unknown-field 1 'release readiness: NO-GO (qualification contract)' "$case_qualification" "$case_artifacts"

copy_case duplicate-field
sed 's/{"schemaVersion":1/{"schemaVersion":1,"schemaVersion":1/' \
    "$case_qualification" >"$case_qualification.duplicate"
mv "$case_qualification.duplicate" "$case_qualification"
expect_result duplicate-field 1 'release readiness: NO-GO (qualification contract)' "$case_qualification" "$case_artifacts"

copy_case wrong-type
plutil -replace distributionRiskAccepted -string true "$case_qualification"
expect_result wrong-type 1 'release readiness: NO-GO (qualification contract)' "$case_qualification" "$case_artifacts"

copy_case failed-gate
plutil -replace accessibilityReview -string failed:0000000000000000000000000000000000000000000000000000000000000008 "$case_qualification"
expect_result failed-gate 1 'release readiness: NO-GO (qualification contract)' "$case_qualification" "$case_artifacts"

copy_case no-go-decision
plutil -replace finalReleaseDecision -string no-go:000000000000000000000000000000000000000000000000000000000000000d "$case_qualification"
expect_result no-go-decision 1 'release readiness: NO-GO (qualification contract)' "$case_qualification" "$case_artifacts"

copy_case source-mismatch
plutil -replace sourceCommit -string 1111111111111111111111111111111111111111 "$case_qualification"
expect_result source-mismatch 1 'release readiness: NO-GO (source binding)' "$case_qualification" "$case_artifacts"

copy_case unapproved-license
plutil -replace licenseIdentifier -string NOASSERTION "$case_qualification"
expect_result unapproved-license 1 'release readiness: NO-GO (license)' "$case_qualification" "$case_artifacts"

copy_case license-mismatch
plutil -replace licenseIdentifier -string Apache-2.0 "$case_qualification"
expect_result license-mismatch 1 'release readiness: NO-GO (license)' "$case_qualification" "$case_artifacts"

copy_case consistently-wrong-license
plutil -replace licenseIdentifier -string Apache-2.0 "$case_qualification"
plutil -replace packages.0.licenseDeclared -string Apache-2.0 \
    "$case_artifacts/SpaceTrace-$version.spdx.json"
rebind_case_hashes
expect_result consistently-wrong-license 1 'release readiness: NO-GO (license)' \
    "$case_qualification" "$case_artifacts"

copy_case risk-not-accepted
plutil -replace distributionRiskAccepted -bool false "$case_qualification"
expect_result risk-not-accepted 1 'release readiness: NO-GO (distribution)' "$case_qualification" "$case_artifacts"

copy_case unsupported-distribution
plutil -replace distributionMode -string developer-id-notarized "$case_qualification"
plutil -replace distributionRiskAccepted -bool false "$case_qualification"
expect_result unsupported-distribution 1 'release readiness: NO-GO (distribution)' "$case_qualification" "$case_artifacts"

copy_case artifact-extra
printf 'unexpected\n' >"$case_artifacts/extra.txt"
expect_result artifact-extra 1 'release readiness: NO-GO (artifact contract)' "$case_qualification" "$case_artifacts"

copy_case checksum-tamper
printf 'tampered\n' >>"$case_artifacts/SpaceTrace-$version.third-party-notices.txt"
expect_result checksum-tamper 1 'release readiness: NO-GO (artifact integrity)' "$case_qualification" "$case_artifacts"

copy_case executable-tamper
printf 'tampered\n' >>"$case_artifacts/SpaceTrace-$version.app/Contents/MacOS/SpaceTrace"
expect_result executable-tamper 1 'release readiness: NO-GO (artifact integrity)' "$case_qualification" "$case_artifacts"

copy_case app-symlink
rm -rf "$case_artifacts/SpaceTrace-$version.app"
ln -s "$canonical_artifacts/SpaceTrace-$version.app" \
    "$case_artifacts/SpaceTrace-$version.app"
expect_result app-symlink 1 'release readiness: NO-GO (artifact contract)' "$case_qualification" "$case_artifacts"

copy_case manifest-binding
plutil -replace manifestSha256 -string ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff "$case_qualification"
expect_result manifest-binding 1 'release readiness: NO-GO (artifact binding)' "$case_qualification" "$case_artifacts"

copy_case wrong-branch
git -C "$fixture_repository" switch -q -c feature
expect_result wrong-branch 1 'release readiness: NO-GO (repository integration)' "$case_qualification" "$case_artifacts"
git -C "$fixture_repository" switch -q main

copy_case dirty-repository
printf 'dirty\n' >"$fixture_repository/untracked.txt"
expect_result dirty-repository 1 'release readiness: NO-GO (repository integration)' "$case_qualification" "$case_artifacts"
rm "$fixture_repository/untracked.txt"

copy_case stale-origin
git -C "$fixture_repository" update-ref refs/remotes/origin/main HEAD^
expect_result stale-origin 1 'release readiness: NO-GO (repository integration)' "$case_qualification" "$case_artifacts"
git -C "$fixture_repository" update-ref refs/remotes/origin/main "$fixture_commit"

copy_case malformed
printf '{\n' >"$case_qualification"
expect_result malformed 1 'release readiness: NO-GO (qualification contract)' "$case_qualification" "$case_artifacts"

copy_case qualification-symlink
rm "$case_qualification"
ln -s "$canonical_qualification" "$case_qualification"
expect_result qualification-symlink 1 'release readiness: NO-GO (qualification contract)' "$case_qualification" "$case_artifacts"

printf 'release readiness contract: %d passed, %d failed\n' "$passed_cases" "$failed_cases"
if [[ $((passed_cases + failed_cases)) -ne $expected_cases ]]; then
    printf 'FAIL: executed %d cases, expected %d\n' \
        "$((passed_cases + failed_cases))" "$expected_cases" >&2
    exit 1
fi
(( failed_cases == 0 ))
