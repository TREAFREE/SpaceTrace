#!/bin/bash

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scratch_root=$(mktemp -d "${TMPDIR:-/tmp}/spacetrace-release-metadata-contract.XXXXXX")
trap 'rm -rf "$scratch_root"' EXIT INT TERM HUP

readonly version=0.1.0-beta.1
readonly license_sha256=c0ea4a896d2c8c394b29f9427589996db826cd501c512279ff0ed3ef48fabbe5
fixture_repository="$scratch_root/repository"
mkdir -p \
    "$fixture_repository/Scripts" \
    "$fixture_repository/Packages/SpaceTraceKit" \
    "$fixture_repository/SpaceTrace.xcodeproj"
cp "$repository_root/Scripts/generate-release-metadata.sh" \
    "$fixture_repository/Scripts/"
cp "$repository_root/Packages/SpaceTraceKit/Package.swift" \
    "$fixture_repository/Packages/SpaceTraceKit/"
cp "$repository_root/SpaceTrace.xcodeproj/project.pbxproj" \
    "$fixture_repository/SpaceTrace.xcodeproj/"
chmod 755 "$fixture_repository/Scripts/generate-release-metadata.sh"
generator="$fixture_repository/Scripts/generate-release-metadata.sh"

git -C "$fixture_repository" init -q -b main
git -C "$fixture_repository" config user.name 'SpaceTrace Tests'
git -C "$fixture_repository" config user.email tests@example.invalid
git -C "$fixture_repository" add Scripts Packages SpaceTrace.xcodeproj
git -C "$fixture_repository" commit -q -m 'fixture without project license'
commit_without_license=$(git -C "$fixture_repository" rev-parse HEAD)

cp "$repository_root/LICENSE.md" "$fixture_repository/LICENSE.md"
unbound_sbom="$scratch_root/unbound.spdx.json"
unbound_notices="$scratch_root/unbound.notices.txt"
if "$generator" \
    --version "$version" \
    --commit "$commit_without_license" \
    --sbom "$unbound_sbom" \
    --notices "$unbound_notices" \
    >"$scratch_root/unbound.stdout" 2>"$scratch_root/unbound.stderr"; then
    printf 'RED: metadata accepted a source commit without the approved license\n' >&2
    exit 1
fi
[[ ! -e $unbound_sbom && ! -e $unbound_notices ]]

git -C "$fixture_repository" add LICENSE.md
git -C "$fixture_repository" commit -q -m 'add approved project license'
commit=$(git -C "$fixture_repository" rev-parse HEAD)
sbom="$scratch_root/SpaceTrace-$version.spdx.json"
notices="$scratch_root/SpaceTrace-$version.third-party-notices.txt"

if [[ ! -f $repository_root/LICENSE.md ]]; then
    printf 'RED: approved project license is missing\n' >&2
    exit 1
fi
[[ $(shasum -a 256 "$repository_root/LICENSE.md" | awk '{print $1}') \
    == "$license_sha256" ]] || {
    printf 'FAIL: approved project license differs from the frozen official text\n' >&2
    exit 1
}

"$generator" \
    --version "$version" \
    --commit "$commit" \
    --sbom "$sbom" \
    --notices "$notices" \
    >"$scratch_root/stdout" 2>"$scratch_root/stderr"

grep -Fxq 'release metadata generation: PASS' "$scratch_root/stdout"
[[ ! -s $scratch_root/stderr ]]
[[ $(plutil -extract packages.0.licenseDeclared raw -expect string -o - "$sbom") \
    == PolyForm-Noncommercial-1.0.0 ]]
[[ $(plutil -extract packages.0.licenseConcluded raw -expect string -o - "$sbom") \
    == PolyForm-Noncommercial-1.0.0 ]]
grep -Fxq \
    'Project license: PolyForm Noncommercial License 1.0.0.' \
    "$notices"
grep -Fxq \
    'https://polyformproject.org/licenses/noncommercial/1.0.0' \
    "$notices"
grep -Fq 'Commercial use is not licensed.' "$notices"
grep -Fq 'Noncommercial use, modification, and distribution are permitted.' \
    "$notices"

if grep -Eq 'MIT License|LicenseRef-' "$sbom" "$notices" \
    || grep -Eq 'NOASSERTION' "$notices" \
    || [[ $(plutil -extract packages.0.licenseDeclared raw -expect string -o - \
        "$sbom") == NOASSERTION ]] \
    || [[ $(plutil -extract packages.0.licenseConcluded raw -expect string -o - \
        "$sbom") == NOASSERTION ]]; then
    printf 'FAIL: release metadata retained an unapproved license declaration\n' >&2
    exit 1
fi
if grep -Fq "$repository_root" "$sbom" "$notices" \
    || grep -Fq "$fixture_repository" "$sbom" "$notices"; then
    printf 'FAIL: release metadata leaked the repository path\n' >&2
    exit 1
fi
[[ $(stat -f '%Lp' "$sbom") == 644 ]]
[[ $(stat -f '%Lp' "$notices") == 644 ]]

printf 'release metadata contract: PASS\n'
