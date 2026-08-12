#!/bin/zsh

set -euo pipefail

readonly generator_version=1
readonly expected_seed="spacetrace-released-v12-20260813"

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
readonly v11_generator="$script_directory/generate-released-schema-v11-fixture.sh"
readonly schema_source="$repository_root/Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteHistoricalCorrectionSchema.swift"
[[ -f "$v11_generator" && -f "$schema_source" ]] || {
    echo "fixture generator inputs are unavailable" >&2
    exit 66
}

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/spacetrace-v12-fixture.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT INT TERM
working_database="$temporary_root/SpaceTrace.sqlite"
"$v11_generator" --output "$working_database" --seed spacetrace-released-v11-20260812 >/dev/null
chmod 0600 "$working_database"

schema_sql="$temporary_root/schema-v12.sql"
sed -n '/private static let schemaSQL = #"""/,/"""#/p' \
    "$schema_source" | sed '1d;$d' | sed 's/^    //' >"$schema_sql"
[[ -s "$schema_sql" ]] || { echo "frozen v12 schema SQL was not extracted" >&2; exit 67; }

sqlite3 -bail "$working_database" <"$schema_sql"
sqlite3 -bail "$working_database" <<'SQL'
PRAGMA foreign_keys=ON;
BEGIN IMMEDIATE;

INSERT INTO scan_run(
    id,stream_id,region_path,dirty_revision_be,state,coverage,entries_seen,
    directories_staged,started_at_ms,finished_at_ms
) VALUES(
    'bbbbbbbb-cccc-dddd-eeee-ffffffffffff','released-v11-stream',
    '/Fixtures/ReleasedV11',X'0000000000000003','completed','complete',2,2,
    2000000011000,2000000011200
);
INSERT INTO historical_observation_batch(
    batch_id,scan_run_id,stream_id_utf8,scope_key,root_subject_key,volume_id,
    mount_generation_id,coverage_epoch_id,path_semantics_version,
    measurement_semantics_version,created_at_ms
) VALUES(
    2,'bbbbbbbb-cccc-dddd-eeee-ffffffffffff',X'72656c65617365642d7631312d73747265616d',
    1,1,X'72656c65617365642d7631312d766f6c756d65',
    X'72656c65617365642d7631312d6d6f756e74',
    X'72656c65617365642d7631312d65706f6368',1,1,2000000011200
);
INSERT INTO historical_observation_frame(frame_id,batch_id,metric)
VALUES(103,2,1),(104,2,2);
INSERT INTO historical_observation_node(
    node_id,batch_id,subject_key,location_key,parent_node_id,observed_at_ms,
    direct_children_coverage,classification_decision_id
) VALUES
    (1003,2,1,1,NULL,2000000011100,1,1),
    (1004,2,2,2,1003,2000000011101,1,1);
INSERT INTO historical_metric_endpoint(
    node_id,metric,frame_id,state_kind,bytes,measurement_coverage,unknown_reason_code
) VALUES
    (1003,1,103,1,6144,1,NULL),(1003,2,104,1,12288,1,NULL),
    (1004,1,103,1,2048,1,NULL),(1004,2,104,1,8192,1,NULL);
INSERT INTO historical_endpoint_stable_identity(
    node_id,guard_kind,generation_token_utf8,birth_seconds,birth_nanoseconds,
    node_kind,link_status
) VALUES
    (1003,1,X'72656c65617365642d726f6f742d746f6b656e',NULL,NULL,1,1),
    (1004,1,X'72656c65617365642d6368696c642d746f6b656e',NULL,NULL,1,1);
INSERT INTO historical_observation_frame_commit(
    sequence,frame_id,root_node_id,root_metric,endpoint_count,committed_at_ms,
    retention_anchor_ms,expires_at_ms
) VALUES
    (3,103,1003,1,2,2000000011200,2000000011100,2002592011100),
    (4,104,1003,2,2,2000000011200,2000000011100,2002592011100);
INSERT INTO historical_calibration_receipt(
    scan_run_id,request_format_version,canonical_request_sha256,outcome,
    logical_sequence,allocated_sequence,committed_at_ms,retention_anchor_ms,
    expires_at_ms
) VALUES(
    'bbbbbbbb-cccc-dddd-eeee-ffffffffffff',1,
    X'2121212121212121212121212121212121212121212121212121212121212121',
    1,3,4,2000000011200,2000000011100,2002592011100
);

INSERT INTO historical_projection_work(
    work_id,baseline_sequence,comparison_sequence,algorithm_version,
    ranking_policy_version,positive_limit,created_at_ms
) VALUES(1,2,4,1,1,10,2000000011200);
INSERT INTO historical_finding_projection(
    projection_id,work_id,format_version,canonical_result_sha256,
    truncated_positive_count,committed_at_ms
) VALUES(
    1,1,1,X'1111111111111111111111111111111111111111111111111111111111111111',
    0,2000000011250
);
INSERT INTO historical_projection_checkpoint(work_id,committed_at_ms)
VALUES(1,2000000011250);

INSERT INTO historical_reconciliation_revision(
    node_id,hourly_predecessor_node_id,daily_predecessor_node_id,
    descendant_count,payload_sha256
) VALUES
    (1001,NULL,NULL,1,X'0101010101010101010101010101010101010101010101010101010101010101'),
    (1002,NULL,NULL,0,X'0202020202020202020202020202020202020202020202020202020202020202'),
    (1003,1001,1001,1,X'0303030303030303030303030303030303030303030303030303030303030303'),
    (1004,1002,1002,0,X'0404040404040404040404040404040404040404040404040404040404040404');
INSERT INTO historical_correction_input(
    algorithm_version,ranking_policy_version,input_format_version,input_sha256,
    canonical_input
) VALUES(
    2,1,1,X'2222222222222222222222222222222222222222222222222222222222222222',
    X'7b2266697874757265223a22763132227d'
);
INSERT INTO historical_projection_correction_work(
    work_id,request_id,request_format_version,canonical_request_sha256,
    root_projection_id,predecessor_correcting_projection_id,
    expected_predecessor_sha256,algorithm_version,ranking_policy_version,
    correction_input_format_version,correction_input_sha256,created_at_ms
) VALUES(
    1,X'33333333333333333333333333333333',1,
    X'3434343434343434343434343434343434343434343434343434343434343434',
    1,NULL,X'1111111111111111111111111111111111111111111111111111111111111111',
    2,1,1,X'2222222222222222222222222222222222222222222222222222222222222222',
    2000000011300
);
INSERT INTO historical_correcting_projection(
    correcting_projection_id,work_id,result_format_version,
    canonical_result_sha256,finding_count,ranked_positive_count,reason_count,
    truncated_positive_count,committed_at_ms,expires_at_ms
) VALUES(
    1,1,1,X'4444444444444444444444444444444444444444444444444444444444444444',
    0,0,0,0,2000000011300,2002592010100
);
INSERT INTO historical_projection_correction_checkpoint(
    work_id,correcting_projection_id,committed_at_ms
) VALUES(1,1,2000000011300);

INSERT INTO schema_migration(version,applied_at_ms,checksum)
VALUES(12,2000000000012,'04fba44ae486b4d2f54324bd2068838675162103846d58abfd89fbdebcd059cf');
PRAGMA user_version=12;
COMMIT;
SQL

sqlite3 -bail "$working_database" 'PRAGMA journal_mode=DELETE; VACUUM;'
sqlite3 -bail "$working_database" 'PRAGMA journal_mode=WAL;'
sqlite3 -bail "$working_database" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null
sqlite3 -bail "$working_database" 'PRAGMA journal_mode=DELETE;' >/dev/null

[[ $(sqlite3 -readonly "$working_database" 'PRAGMA quick_check') == ok ]] || {
    echo "v12 fixture quick_check failed" >&2
    exit 68
}
[[ -z $(sqlite3 -readonly "$working_database" 'PRAGMA foreign_key_check') ]] || {
    echo "v12 fixture foreign_key_check failed" >&2
    exit 68
}
[[ $(sqlite3 -readonly "$working_database" 'PRAGMA user_version') == 12 ]] || {
    echo "v12 fixture has the wrong schema version" >&2
    exit 68
}
[[ $(sqlite3 -readonly "$working_database" 'SELECT count(*) FROM historical_reconciliation_revision') == 4 ]] || {
    echo "v12 fixture revision chain is incomplete" >&2
    exit 68
}
[[ $(sqlite3 -readonly "$working_database" 'SELECT count(*) FROM historical_projection_correction_checkpoint') == 1 ]] || {
    echo "v12 fixture correction checkpoint is incomplete" >&2
    exit 68
}

mkdir -p "${output_path:h}"
temporary_output="${output_path}.tmp.$$"
cp "$working_database" "$temporary_output"
chmod 0644 "$temporary_output"
mv -f "$temporary_output" "$output_path"
printf 'schemaVersion=12\ngeneratorVersion=%s\nseed=%s\nsha256=%s\n' \
    "$generator_version" "$expected_seed" \
    "$(shasum -a 256 "$output_path" | awk '{print $1}')"
