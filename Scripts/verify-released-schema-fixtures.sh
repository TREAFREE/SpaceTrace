#!/bin/bash

set -euo pipefail

readonly script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly repository_root=$(cd -- "$script_directory/.." && pwd -P)
readonly fixture_root="$repository_root/Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas"
readonly manifest_path="$fixture_root/manifest.json"
readonly maximum_manifest_bytes=65536
readonly maximum_fixture_bytes=4194304

fail() {
    echo "released-schema fixture verification failed: $1" >&2
    exit 1
}

for dependency in jq sqlite3 shasum stat cmp xxd; do
    command -v "$dependency" >/dev/null 2>&1 || {
        echo "released-schema fixture verification infrastructure is unavailable" >&2
        exit 2
    }
done

[[ -f "$manifest_path" && ! -L "$manifest_path" ]] || fail "manifest is not a regular file"
[[ $(stat -f '%Lp' "$manifest_path") == 644 ]] || fail "manifest mode is not 0644"
manifest_bytes=$(stat -f '%z' "$manifest_path")
(( manifest_bytes > 0 && manifest_bytes <= maximum_manifest_bytes )) || \
    fail "manifest exceeds its byte bound"

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/spacetrace-fixture-verifier.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT INT TERM
canonical_manifest="$temporary_root/manifest.json"

jq -e '
    type == "object" and
    (keys == ["fixtures", "formatVersion"]) and
    (.formatVersion | type == "number" and . == 2 and floor == .) and
    (.fixtures | type == "array" and length == 3) and
    ([.fixtures[].schemaVersion] == [10, 11, 12]) and
    all(.fixtures[];
        type == "object" and
        (keys == [
            "generatorPath", "generatorSHA256", "generatorVersion",
            "relativePath", "schemaObjectSHA256", "schemaVersion", "seed",
            "semanticSHA256", "sha256"
        ]) and
        (.schemaVersion | type == "number" and floor == .) and
        (.relativePath | type == "string") and
        (.sha256 | type == "string") and
        (.generatorPath | type == "string") and
        (.generatorSHA256 | type == "string") and
        (.generatorVersion | type == "number" and floor == . and . > 0) and
        (.seed | type == "string" and (length > 0 and length <= 128)) and
        (.semanticSHA256 | type == "string") and
        (.schemaObjectSHA256 | type == "string")
    )
' "$manifest_path" >/dev/null || fail "manifest shape or JSON types are invalid"

jq '{
    formatVersion: .formatVersion,
    fixtures: [.fixtures[] | {
        schemaVersion: .schemaVersion,
        relativePath: .relativePath,
        sha256: .sha256,
        generatorPath: .generatorPath,
        generatorSHA256: .generatorSHA256,
        generatorVersion: .generatorVersion,
        seed: .seed,
        semanticSHA256: .semanticSHA256,
        schemaObjectSHA256: .schemaObjectSHA256
    }]
}' "$manifest_path" >"$canonical_manifest" || fail "manifest cannot be canonicalized"
cmp -s "$manifest_path" "$canonical_manifest" || \
    fail "manifest is noncanonical or contains duplicate/unknown keys"

valid_sha256() {
    local value=$1
    (( ${#value} == 64 )) && [[ "$value" != *[^0-9a-f]* ]]
}

schema_digest() {
    local database=$1
    sqlite3 -readonly "file:${database}?immutable=1" \
        "SELECT type||char(9)||hex(CAST(name AS BLOB))||char(9)||hex(CAST(tbl_name AS BLOB))||char(9)||coalesce(hex(CAST(sql AS BLOB)),'') FROM sqlite_schema WHERE type IN ('table','index','trigger') AND name NOT LIKE 'sqlite_%' ORDER BY CAST(type AS BLOB),CAST(name AS BLOB),CAST(tbl_name AS BLOB);" \
        | shasum -a 256 | awk '{print $1}'
}

semantic_digest() {
    local database=$1
    sqlite3 -readonly "file:${database}?immutable=1" '.dump --data-only' \
        | shasum -a 256 | awk '{print $1}'
}

verify_sqlite() {
    local database=$1
    local version=$2
    local header
    local quick_check
    local foreign_keys
    local actual_version
    local immutable_uri="file:${database}?immutable=1"

    [[ -f "$database" && ! -L "$database" ]] || fail "fixture is not a regular file"
    [[ $(stat -f '%Lp' "$database") == 644 ]] || fail "fixture mode is not 0644"
    local byte_count=$(stat -f '%z' "$database")
    (( byte_count >= 4096 && byte_count <= maximum_fixture_bytes )) || \
        fail "fixture exceeds its byte bound"
    header=$(xxd -p -l 16 "$database")
    [[ "$header" == 53514c69746520666f726d6174203300 ]] || \
        fail "fixture lacks a SQLite header"
    quick_check=$(sqlite3 -readonly "$immutable_uri" 'PRAGMA quick_check') || \
        fail "fixture cannot be opened read-only"
    [[ "$quick_check" == ok ]] || fail "fixture quick_check failed"
    foreign_keys=$(sqlite3 -readonly "$immutable_uri" 'PRAGMA foreign_key_check') || \
        fail "fixture foreign_key_check could not run"
    [[ -z "$foreign_keys" ]] || fail "fixture has foreign-key violations"
    actual_version=$(sqlite3 -readonly "$immutable_uri" 'PRAGMA user_version') || \
        fail "fixture version could not be read"
    [[ "$actual_version" == "$version" ]] || fail "fixture version disagrees with manifest"
}

typeset -A expected_byte_digest expected_generator_digest expected_seed
typeset -A expected_semantic_digest expected_schema_digest
expected_byte_digest[10]=f410f4d3aee861a09f1128661a98082cc19c53bc9662cbde761409506dfa5dec
expected_byte_digest[11]=5a471cf3f76622411b8fed60043fe837b4bdc4f3a0b811a20818aa84b6ca2945
expected_byte_digest[12]=360a23821d8cb5b37a56047052b8d45ab0b80daae9d554d1f3aec0109bcb4e42
expected_generator_digest[10]=2145d8b0a04ee446be7072c26798ec4605122074d2b3a5c08e92c502a491eebe
expected_generator_digest[11]=4ad02a80505b0ccc00ea4998c3cea28d8589bf26044ec772e0b981b22c84abf8
expected_generator_digest[12]=b1c6c60d6c71bf57c0f96c4208fcf67945c42563d554f93119a8ea371541ac38
expected_seed[10]=spacetrace-released-v10-20260812
expected_seed[11]=spacetrace-released-v11-20260812
expected_seed[12]=spacetrace-released-v12-20260813
expected_semantic_digest[10]=9489396aeb50cf8c369a61051201078ce0f858033a4f66a46de6be3fe8356c5b
expected_semantic_digest[11]=f9b1394b6e1ee144548d8ad5179cd5ba8917891fe13064ab9493e463ed1a9414
expected_semantic_digest[12]=ac6fdb5e1edfaabce652bd3a67a180e2fa1d6a918d25d4b1277068816e48131f
expected_schema_digest[10]=f9a79fcd1b5ad9912fb9e796ed7f66358c18092fb665071ec937283f050e02e3
expected_schema_digest[11]=8d5d1cb9d992ba944ad67c4100a56a6c8e521fe3bf6ef02b27a620f9e1ba08f7
expected_schema_digest[12]=9f401f317d53a3c9c8f71fc7e0afdd2bfe043604c720edacf83cfd4f5ecbee0f

for version in 10 11 12; do
    entry=$(jq -c --argjson version "$version" \
        '.fixtures[] | select(.schemaVersion == $version)' "$manifest_path")
    [[ -n "$entry" ]] || fail "manifest omits schema v$version"
    relative_path=$(jq -r '.relativePath' <<<"$entry")
    generator_path=$(jq -r '.generatorPath' <<<"$entry")
    byte_digest=$(jq -r '.sha256' <<<"$entry")
    generator_digest=$(jq -r '.generatorSHA256' <<<"$entry")
    seed=$(jq -r '.seed' <<<"$entry")
    semantic=$(jq -r '.semanticSHA256' <<<"$entry")
    schema=$(jq -r '.schemaObjectSHA256' <<<"$entry")

    [[ "$relative_path" == "v${version}/SpaceTrace.sqlite" ]] || \
        fail "fixture path is noncanonical"
    [[ "$generator_path" == "Scripts/Fixtures/generate-released-schema-v${version}-fixture.sh" ]] || \
        fail "generator path is noncanonical"
    for digest in "$byte_digest" "$generator_digest" "$semantic" "$schema"; do
        valid_sha256 "$digest" || fail "manifest contains an invalid digest"
    done
    [[ "$byte_digest" == "${expected_byte_digest[$version]}" &&
       "$generator_digest" == "${expected_generator_digest[$version]}" &&
       "$seed" == "${expected_seed[$version]}" &&
       "$semantic" == "${expected_semantic_digest[$version]}" &&
       "$schema" == "${expected_schema_digest[$version]}" ]] || \
        fail "manifest provenance differs from the reviewed v$version release fixture"

    fixture="$fixture_root/$relative_path"
    generator="$repository_root/$generator_path"
    [[ -f "$generator" && ! -L "$generator" ]] || fail "generator is not a regular file"
    [[ $(stat -f '%Lp' "$generator") == 755 ]] || fail "generator mode is not 0755"
    [[ $(shasum -a 256 "$generator" | awk '{print $1}') == "$generator_digest" ]] || \
        fail "generator digest mismatch"
    verify_sqlite "$fixture" "$version"
    [[ $(shasum -a 256 "$fixture" | awk '{print $1}') == "$byte_digest" ]] || \
        fail "fixture byte digest mismatch"
    [[ $(semantic_digest "$fixture") == "$semantic" ]] || \
        fail "fixture semantic digest mismatch"
    [[ $(schema_digest "$fixture") == "$schema" ]] || \
        fail "fixture schema-object digest mismatch"

    regenerated="$temporary_root/v${version}/SpaceTrace.sqlite"
    mkdir -p "$(dirname -- "$regenerated")"
    "$generator" --output "$regenerated" --seed "$seed" >/dev/null || \
        fail "fixture regeneration failed"
    verify_sqlite "$regenerated" "$version"
    cmp -s "$fixture" "$regenerated" || \
        fail "fixture regeneration is not byte-identical"
done

typeset -A legacy_digest
legacy_digest[6]=5a5bbe6cdf57ac6c5e4398a771b6505e29e4775b4f321fd5ed1097ff30bae528
legacy_digest[7]=beccfcbf1bf40ad2f3f89997d58f61aeacb7b0126ed9a4c813b9448a3cdfb95c
legacy_digest[8]=8d2d9468362f685e8e485ae291d007c0b70aaf06d691dd8ff2f50c2de506eeb5
legacy_digest[9]=fdc8a4452202260b6bbefd47c122c60e98ad7a959f184646a06ed067817c7108
for version in 6 7 8 9; do
    fixture="$fixture_root/v${version}/SpaceTrace.sqlite"
    verify_sqlite "$fixture" "$version"
    [[ $(shasum -a 256 "$fixture" | awk '{print $1}') == "${legacy_digest[$version]}" ]] || \
        fail "frozen legacy fixture v$version changed"
done

[[ $(sqlite3 -readonly "file:$fixture_root/v10/SpaceTrace.sqlite?immutable=1" \
    "SELECT count(*) FROM node_current WHERE path LIKE '/Fixtures/%'") -ge 2 ]] || \
    fail "v10 fixture is not populated"
[[ $(sqlite3 -readonly "file:$fixture_root/v11/SpaceTrace.sqlite?immutable=1" \
    'SELECT count(*) FROM historical_observation_node') -eq 2 ]] || \
    fail "v11 fixture is not populated"
[[ $(sqlite3 -readonly "file:$fixture_root/v11/SpaceTrace.sqlite?immutable=1" \
    "SELECT checksum FROM schema_migration WHERE version=11") == \
    38821bf16852476d4457a4921462257b5b194a1fe5703de02d1ee4f8c63e5371 ]] || \
    fail "v11 repository schema digest is not frozen"
[[ $(sqlite3 -readonly "file:$fixture_root/v12/SpaceTrace.sqlite?immutable=1" \
    'SELECT count(*) FROM historical_reconciliation_revision') -eq 4 ]] || \
    fail "v12 fixture revision chain is not populated"
[[ $(sqlite3 -readonly "file:$fixture_root/v12/SpaceTrace.sqlite?immutable=1" \
    'SELECT count(*) FROM historical_projection_correction_checkpoint') -eq 1 ]] || \
    fail "v12 fixture correcting projection is not committed"
[[ $(sqlite3 -readonly "file:$fixture_root/v12/SpaceTrace.sqlite?immutable=1" \
    "SELECT checksum FROM schema_migration WHERE version=12") == \
    04fba44ae486b4d2f54324bd2068838675162103846d58abfd89fbdebcd059cf ]] || \
    fail "v12 repository schema digest is not frozen"

echo "Released-schema fixtures are reproducible and valid."
