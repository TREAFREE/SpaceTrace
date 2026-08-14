#!/bin/zsh

set -euo pipefail

program_name=${0:t}

usage() {
    print -u2 "usage: $program_name --version <semver> --commit <40-hex> --sbom <new-file> --notices <new-file>"
}

fail() {
    print -u2 "error: $1"
    exit "${2:-2}"
}

version=""
commit=""
sbom=""
notices=""

while (( $# > 0 )); do
    case "$1" in
        --version)
            (( $# >= 2 )) || { usage; exit 64; }
            version=$2
            shift 2
            ;;
        --commit)
            (( $# >= 2 )) || { usage; exit 64; }
            commit=$2
            shift 2
            ;;
        --sbom)
            (( $# >= 2 )) || { usage; exit 64; }
            sbom=$2
            shift 2
            ;;
        --notices)
            (( $# >= 2 )) || { usage; exit 64; }
            notices=$2
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

[[ -n $version && -n $commit && -n $sbom && -n $notices ]] || {
    usage
    exit 64
}
print -r -- "$version" | /usr/bin/grep -Eq \
    '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$' \
    || fail "version must be valid Semantic Versioning" 64
print -r -- "$commit" | /usr/bin/grep -Eq '^[0-9a-f]{40}$' \
    || fail "commit must be exactly 40 lowercase hexadecimal characters" 64

script_directory=${0:A:h}
repository_root=${script_directory:h}
cd "$repository_root"

readonly project_license_identifier=PolyForm-Noncommercial-1.0.0
readonly project_license_name='PolyForm Noncommercial License 1.0.0'
readonly project_license_url='https://polyformproject.org/licenses/noncommercial/1.0.0'
readonly project_license_sha256=c0ea4a896d2c8c394b29f9427589996db826cd501c512279ff0ed3ef48fabbe5

[[ $(git rev-parse --show-toplevel) == $repository_root ]] \
    || fail "script must run from the SpaceTrace Git worktree"
resolved_commit=$(git rev-parse --verify "$commit^{commit}" 2>/dev/null) \
    || fail "commit does not resolve to a local Git commit"
[[ $resolved_commit == $commit ]] || fail "commit did not resolve exactly"

[[ -f LICENSE.md && ! -L LICENSE.md ]] \
    || fail "approved project license is missing or not a regular file"
actual_license_sha256=$(/usr/bin/shasum -a 256 LICENSE.md \
    | /usr/bin/awk '{print $1}')
[[ $actual_license_sha256 == $project_license_sha256 ]] \
    || fail "approved project license does not match the frozen official text"
committed_license_sha256=$(git cat-file blob "$commit:LICENSE.md" 2>/dev/null \
    | /usr/bin/shasum -a 256 \
    | /usr/bin/awk '{print $1}') \
    || fail "source commit does not contain the approved project license"
[[ $committed_license_sha256 == $project_license_sha256 ]] \
    || fail "source commit license does not match the frozen official text"

[[ ! -e Packages/SpaceTraceKit/Package.resolved ]] \
    || fail "release metadata forbids a Swift package resolution file"
if /usr/bin/grep -Eq '\.package[[:space:]]*\(' Packages/SpaceTraceKit/Package.swift; then
    fail "release metadata forbids remote Swift package dependencies"
fi
if /usr/bin/grep -Eq \
    'XCRemoteSwiftPackageReference|repositoryURL[[:space:]]*=' \
    SpaceTrace.xcodeproj/project.pbxproj; then
    fail "release metadata forbids Xcode remote package dependencies"
fi

[[ $sbom == /* && $notices == /* ]] \
    || fail "SBOM and notices output paths must be absolute" 64
[[ $sbom != $notices ]] || fail "SBOM and notices outputs must be different" 64
[[ ! -e $sbom ]] || fail "SBOM output already exists: $sbom"
[[ ! -e $notices ]] || fail "notices output already exists: $notices"

sbom_parent=${sbom:h}
notices_parent=${notices:h}
[[ -d $sbom_parent && -d $notices_parent ]] \
    || fail "SBOM and notices parent directories must already exist"

sbom_stage=$(mktemp "$sbom_parent/.spacetrace-sbom.XXXXXX")
notices_stage=$(mktemp "$notices_parent/.spacetrace-notices.XXXXXX")
plist_stage=$(mktemp "${TMPDIR:-/private/tmp}/spacetrace-spdx.XXXXXX")

cleanup() {
    rm -f -- "$sbom_stage" "$notices_stage" "$plist_stage"
}
trap cleanup EXIT

commit_epoch=$(git show -s --format=%ct "$commit")
created_at=$(/bin/date -u -r "$commit_epoch" '+%Y-%m-%dT%H:%M:%SZ')
namespace_version=${version//+/%2B}
document_namespace="https://github.com/TREAFREE/SpaceTrace/spdx/SpaceTrace-$namespace_version-$commit"

/usr/bin/plutil -create xml1 "$plist_stage"
/usr/bin/plutil -insert spdxVersion -string SPDX-2.3 "$plist_stage"
/usr/bin/plutil -insert dataLicense -string CC0-1.0 "$plist_stage"
/usr/bin/plutil -insert SPDXID -string SPDXRef-DOCUMENT "$plist_stage"
/usr/bin/plutil -insert name -string "SpaceTrace-$version" "$plist_stage"
/usr/bin/plutil -insert documentNamespace -string "$document_namespace" "$plist_stage"
/usr/bin/plutil -insert creationInfo -dictionary "$plist_stage"
/usr/bin/plutil -insert creationInfo.created -string "$created_at" "$plist_stage"
/usr/bin/plutil -insert creationInfo.creators -json \
    '["Tool: SpaceTrace release tooling"]' "$plist_stage"
/usr/bin/plutil -insert packages -array "$plist_stage"
/usr/bin/plutil -insert packages.0 -dictionary "$plist_stage"
/usr/bin/plutil -insert packages.0.name -string SpaceTrace "$plist_stage"
/usr/bin/plutil -insert packages.0.SPDXID -string SPDXRef-Package-SpaceTrace "$plist_stage"
/usr/bin/plutil -insert packages.0.versionInfo -string "$version" "$plist_stage"
/usr/bin/plutil -insert packages.0.downloadLocation -string \
    "https://github.com/TREAFREE/SpaceTrace/tree/$commit" "$plist_stage"
/usr/bin/plutil -insert packages.0.filesAnalyzed -bool false "$plist_stage"
/usr/bin/plutil -insert packages.0.licenseConcluded -string \
    "$project_license_identifier" "$plist_stage"
/usr/bin/plutil -insert packages.0.licenseDeclared -string \
    "$project_license_identifier" "$plist_stage"
/usr/bin/plutil -insert packages.0.copyrightText -string NOASSERTION "$plist_stage"
/usr/bin/plutil -insert packages.0.primaryPackagePurpose -string APPLICATION "$plist_stage"
/usr/bin/plutil -insert packages.0.summary -string \
    "SpaceTrace is a privacy-first macOS storage history and attribution utility." \
    "$plist_stage"
/usr/bin/plutil -insert packages.0.comment -string \
    "No external Swift package dependency or bundled third-party library is present in this release graph." \
    "$plist_stage"
/usr/bin/plutil -insert packages.0.externalRefs -array "$plist_stage"
/usr/bin/plutil -insert packages.0.externalRefs.0 -dictionary "$plist_stage"
/usr/bin/plutil -insert packages.0.externalRefs.0.referenceCategory -string PACKAGE-MANAGER "$plist_stage"
/usr/bin/plutil -insert packages.0.externalRefs.0.referenceType -string purl "$plist_stage"
/usr/bin/plutil -insert packages.0.externalRefs.0.referenceLocator -string \
    "pkg:github/TREAFREE/SpaceTrace@$commit" "$plist_stage"
/usr/bin/plutil -insert relationships -array "$plist_stage"
/usr/bin/plutil -insert relationships.0 -dictionary "$plist_stage"
/usr/bin/plutil -insert relationships.0.spdxElementId -string SPDXRef-DOCUMENT "$plist_stage"
/usr/bin/plutil -insert relationships.0.relationshipType -string DESCRIBES "$plist_stage"
/usr/bin/plutil -insert relationships.0.relatedSpdxElement -string \
    SPDXRef-Package-SpaceTrace "$plist_stage"
/usr/bin/plutil -lint "$plist_stage" >/dev/null
/usr/bin/plutil -convert json -o "$sbom_stage" "$plist_stage"
[[ $(/usr/bin/plutil -extract spdxVersion raw -o - "$sbom_stage") == SPDX-2.3 ]] \
    || fail "generated SBOM is not readable SPDX JSON"

{
    print 'SpaceTrace Third-Party Notices'
    print '================================'
    print
    print 'No third-party libraries are embedded in SpaceTrace.app.'
    print
    print 'The release links only to Apple platform frameworks, the system Swift runtime,'
    print 'and the system libsqlite3 supplied by macOS. Those components are provided by'
    print 'the operating system and are not redistributed as third-party packages here.'
    print
    print "Project license: $project_license_name."
    print "$project_license_url"
    print 'Commercial use is not licensed.'
    print 'Noncommercial use, modification, and distribution are permitted.'
    print 'SpaceTrace is source-available and is not offered as OSI-approved open source.'
    print
    print "Release: $version"
    print "Source commit: $commit"
} >"$notices_stage"

if /usr/bin/grep -Fq "$repository_root" "$sbom_stage" "$notices_stage"; then
    fail "generated metadata contains the local repository path"
fi

chmod 0644 "$sbom_stage" "$notices_stage"
/bin/ln "$sbom_stage" "$sbom" || fail "SBOM output appeared concurrently"
/bin/ln "$notices_stage" "$notices" || {
    /bin/rm -f -- "$sbom"
    fail "notices output appeared concurrently"
}

print "release metadata generation: PASS"
