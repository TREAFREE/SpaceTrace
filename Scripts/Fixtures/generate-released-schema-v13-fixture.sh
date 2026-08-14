#!/bin/zsh

set -euo pipefail

readonly generator_version=1
readonly expected_seed="spacetrace-released-v13-20260813"

usage() {
    echo "usage: $0 --output PATH --seed $expected_seed" >&2
    exit 64
}

output_path=""
seed=""
while (( $# > 0 )); do
    case "$1" in
        --output)
            (( $# >= 2 )) || usage
            output_path=$2
            shift 2
            ;;
        --seed)
            (( $# >= 2 )) || usage
            seed=$2
            shift 2
            ;;
        *) usage ;;
    esac
done

[[ -n "$output_path" && "$seed" == "$expected_seed" ]] || usage
[[ ! -L "$output_path" ]] || { echo "output must not be a symlink" >&2; exit 65; }

readonly script_directory=${0:A:h}
readonly repository_root=${script_directory:h:h}
readonly v12_generator="$script_directory/generate-released-schema-v12-fixture.sh"
readonly schema_source="$repository_root/Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteHistoricalCorrectedRetractionSchema.swift"
[[ -f "$v12_generator" && -f "$schema_source" ]] || {
    echo "fixture generator inputs are unavailable" >&2
    exit 66
}

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/spacetrace-v13-fixture.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT INT TERM
working_database="$temporary_root/SpaceTrace.sqlite"
"$v12_generator" --output "$working_database" --seed spacetrace-released-v12-20260813 >/dev/null
chmod 0600 "$working_database"

schema_sql="$temporary_root/schema-v13.sql"
sed -n '/private static let schemaSQL = #"""/,/"""#/p' \
    "$schema_source" | sed '1d;$d' | sed 's/^    //' >"$schema_sql"
[[ -s "$schema_sql" ]] || { echo "frozen v13 schema SQL was not extracted" >&2; exit 67; }

sqlite3 -bail "$working_database" <"$schema_sql"
sqlite3 -bail "$working_database" <<'SQL'
PRAGMA foreign_keys=ON;
BEGIN IMMEDIATE;
INSERT INTO schema_migration(version,applied_at_ms,checksum)
VALUES(13,2000000000013,'cd10e239cc6067a77c4e51a0d862ad6942c406b24a2ca2962304bd77ffbc49a4');
PRAGMA user_version=13;
COMMIT;
SQL

sqlite3 -bail "$working_database" 'PRAGMA journal_mode=DELETE; VACUUM;'
sqlite3 -bail "$working_database" 'PRAGMA journal_mode=WAL;'
sqlite3 -bail "$working_database" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null
sqlite3 -bail "$working_database" 'PRAGMA journal_mode=DELETE;' >/dev/null

[[ $(sqlite3 -readonly "$working_database" 'PRAGMA quick_check') == ok ]] || {
    echo "v13 fixture quick_check failed" >&2
    exit 68
}
[[ -z $(sqlite3 -readonly "$working_database" 'PRAGMA foreign_key_check') ]] || {
    echo "v13 fixture foreign_key_check failed" >&2
    exit 68
}
[[ $(sqlite3 -readonly "$working_database" 'PRAGMA user_version') == 13 ]] || {
    echo "v13 fixture has the wrong schema version" >&2
    exit 68
}
[[ $(sqlite3 -readonly "$working_database" 'SELECT count(*) FROM historical_projection_correction_checkpoint') == 1 ]] || {
    echo "v13 fixture lost its v12 correction checkpoint" >&2
    exit 68
}
[[ $(sqlite3 -readonly "$working_database" 'SELECT count(*) FROM historical_corrected_finding_retraction') == 0 ]] || {
    echo "v13 fixture invented a corrected-finding invalidation" >&2
    exit 68
}

mkdir -p "${output_path:h}"
temporary_output="${output_path}.tmp.$$"
cp "$working_database" "$temporary_output"
chmod 0644 "$temporary_output"
mv -f "$temporary_output" "$output_path"
printf 'schemaVersion=13\ngeneratorVersion=%s\nseed=%s\nsha256=%s\n' \
    "$generator_version" "$expected_seed" \
    "$(shasum -a 256 "$output_path" | awk '{print $1}')"
