#!/bin/zsh

set -euo pipefail

readonly generator_version=1
readonly expected_seed="spacetrace-released-v10-20260812"

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
readonly migration_source="$repository_root/Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteEventJournalRepository.swift"
[[ -f "$migration_source" && ! -L "$migration_source" ]] || {
    echo "repository migration source is unavailable" >&2
    exit 66
}

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/spacetrace-v10-fixture.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT INT TERM
working_database="$temporary_root/SpaceTrace.sqlite"
migration_sql="$temporary_root/migration-v10.sql"
for migration_name in One Two Three Four Five Six Seven Eight Nine Ten; do
    awk -v marker="private static func migrateToVersion${migration_name}(" '
        index($0, marker) { active=1; next }
        active && /^    private static func / { exit }
        active { print }
    ' "$migration_source" | sed -n '/"""/,/"""/p' | sed '1d;$d' \
        | sed 's/^                //' >>"$migration_sql"
done
[[ -s "$migration_sql" ]] || { echo "migration v10 SQL was not extracted" >&2; exit 67; }
sqlite3 -bail "$working_database" <<SQL
PRAGMA foreign_keys=ON;
PRAGMA secure_delete=ON;
PRAGMA journal_mode=DELETE;
.read $migration_sql
SQL
chmod 0600 "$working_database"

sqlite3 -bail "$working_database" <<'SQL'
PRAGMA foreign_keys=ON;
BEGIN IMMEDIATE;
DELETE FROM path_free_calibration_requirement;
DELETE FROM directory_history_sample;
DELETE FROM authorized_baseline_root;
DELETE FROM authorized_baseline_snapshot;
DELETE FROM watched_scope_bookmark;
DELETE FROM scope_mount_generation;
DELETE FROM node_current;
DELETE FROM scan_node_stage;
DELETE FROM scan_run;
DELETE FROM dirty_region;
DELETE FROM event_checkpoint;
DELETE FROM startup_volume_capacity_sample;

UPDATE schema_migration SET applied_at_ms=2000000000000 + version;

INSERT INTO event_checkpoint(stream_id,cursor_be)
VALUES('released-v10-stream',X'000000000000002a');
INSERT INTO scan_run(
    id,stream_id,region_path,dirty_revision_be,state,coverage,entries_seen,
    directories_staged,started_at_ms,finished_at_ms
) VALUES(
    'released-v10-run','released-v10-stream','/Fixtures/ReleasedV10',
    X'0000000000000001','completed','complete',2,2,
    2000000000100,2000000000200
);
INSERT INTO node_current(
    stream_id,path,logical_bytes,allocated_bytes,descendant_count,coverage,
    last_scan_run_id,deleted,deleted_at_ms
) VALUES
    ('released-v10-stream','/Fixtures/ReleasedV10',4096,8192,1,'complete',
     'released-v10-run',0,NULL),
    ('released-v10-stream','/Fixtures/ReleasedV10/Child',1024,4096,0,'complete',
     'released-v10-run',0,NULL);
INSERT INTO directory_history_sample(
    stream_id,path,bucket_kind,bucket_start_ms,logical_bytes,logical_delta,
    allocated_bytes,descendant_count,coverage,scan_run_id
) VALUES(
    'released-v10-stream','/Fixtures/ReleasedV10','daily',1999987200000,
    4096,512,8192,1,'complete','released-v10-run'
);
INSERT INTO watched_scope_bookmark(
    scope_id,bookmark,expected_root,expected_volume_uuid,created_at_ms,updated_at_ms
) VALUES(
    'released-v10-scope',X'0102030405060708','/Fixtures/ReleasedV10',
    '11111111-2222-3333-4444-555555555555',2000000000000,2000000000000
);
INSERT INTO scope_mount_generation(
    scope_id,mount_generation,mount_path,volume_uuid,is_active,updated_at_ms
) VALUES(
    'released-v10-scope','released-v10-generation','/Fixtures/ReleasedV10',
    '11111111-2222-3333-4444-555555555555',0,2000000000000
);
INSERT INTO authorized_baseline_snapshot(
    id,started_at_ms,committed_at_ms,app_version,schema_version,
    volume_observed_at_ms,volume_uuid,volume_total_bytes,volume_available_bytes,
    volume_important_available_bytes,coverage,root_count
) VALUES(
    'released-v10-baseline',2000000000000,2000000000200,'fixture-1',10,
    2000000000100,'11111111-2222-3333-4444-555555555555',1000000000,
    600000000,550000000,'complete',1
);
INSERT INTO authorized_baseline_root(
    baseline_id,ordinal,scope_id,stream_id,root_path,logical_bytes,
    allocated_bytes,descendant_count,entries_visited,directories_observed,
    coverage,volume_uuid
) VALUES(
    'released-v10-baseline',0,'released-v10-scope','released-v10-stream',
    '/Fixtures/ReleasedV10',4096,8192,1,2,2,'complete',
    '11111111-2222-3333-4444-555555555555'
);
INSERT INTO startup_volume_capacity_sample(
    sequence,observed_at_ms,volume_uuid,total_bytes,available_bytes,
    important_available_bytes,source
) VALUES
    (1,2000000000000,'11111111-2222-3333-4444-555555555555',1000000000,600000000,550000000,'baseline'),
    (2,2000000001000,'11111111-2222-3333-4444-555555555555',1000000000,599000000,549000000,'sleep_boundary'),
    (3,2000000002000,'11111111-2222-3333-4444-555555555555',1000000000,598000000,548000000,'wake_boundary');

PRAGMA user_version=10;
COMMIT;
SQL
sqlite3 -bail "$working_database" 'PRAGMA journal_mode=DELETE; VACUUM;'
sqlite3 -bail "$working_database" 'PRAGMA journal_mode=WAL;'
sqlite3 -bail "$working_database" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null
sqlite3 -bail "$working_database" 'PRAGMA journal_mode=DELETE;' >/dev/null

[[ $(sqlite3 -readonly "$working_database" 'PRAGMA quick_check') == ok ]] || {
    echo "v10 fixture quick_check failed" >&2
    exit 67
}
[[ -z $(sqlite3 -readonly "$working_database" 'PRAGMA foreign_key_check') ]] || {
    echo "v10 fixture foreign_key_check failed" >&2
    exit 67
}
[[ $(sqlite3 -readonly "$working_database" 'PRAGMA user_version') == 10 ]] || {
    echo "v10 fixture has the wrong schema version" >&2
    exit 67
}

mkdir -p "${output_path:h}"
temporary_output="${output_path}.tmp.$$"
cp "$working_database" "$temporary_output"
chmod 0644 "$temporary_output"
mv -f "$temporary_output" "$output_path"
printf 'schemaVersion=10\ngeneratorVersion=%s\nseed=%s\nsha256=%s\n' \
    "$generator_version" "$expected_seed" \
    "$(shasum -a 256 "$output_path" | awk '{print $1}')"
