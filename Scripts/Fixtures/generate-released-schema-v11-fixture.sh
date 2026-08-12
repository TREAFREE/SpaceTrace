#!/bin/zsh

set -euo pipefail

readonly generator_version=1
readonly expected_seed="spacetrace-released-v11-20260812"

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
readonly v10_generator="$script_directory/generate-released-schema-v10-fixture.sh"
readonly schema_source="$repository_root/Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteHistoricalFindingSchema.swift"
[[ -f "$v10_generator" && -f "$schema_source" ]] || {
    echo "fixture generator inputs are unavailable" >&2
    exit 66
}

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/spacetrace-v11-fixture.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT INT TERM
working_database="$temporary_root/SpaceTrace.sqlite"
"$v10_generator" --output "$working_database" --seed spacetrace-released-v10-20260812 >/dev/null
chmod 0600 "$working_database"

schema_sql="$temporary_root/schema-v11.sql"
sed -n '/private static let schemaSQL = #"""/,/"""# + immutableTriggerSQL/p' \
    "$schema_source" | sed '1d;$d' | sed 's/^    //' >"$schema_sql"
[[ -s "$schema_sql" ]] || { echo "frozen v11 schema SQL was not extracted" >&2; exit 67; }

sqlite3 -bail "$working_database" <<'SQL'
PRAGMA foreign_keys=ON;
PRAGMA secure_delete=ON;
PRAGMA journal_mode=DELETE;
PRAGMA auto_vacuum=FULL;
VACUUM;
SQL
sqlite3 -bail "$working_database" <"$schema_sql"

typeset -a immutable_mappings=(
    historical_store_identity_immutable_update historical_store_identity
    historical_scope_immutable_update historical_scope
    historical_subject_immutable_update historical_subject
    historical_location_immutable_update historical_location
    historical_attribution_decision_immutable_update frozen_attribution_decision
    historical_attribution_competitor_immutable_update frozen_attribution_competitor
    historical_batch_immutable_update historical_observation_batch
    historical_frame_immutable_update historical_observation_frame
    historical_node_immutable_update historical_observation_node
    historical_metric_endpoint_immutable_update historical_metric_endpoint
    historical_stable_identity_immutable_update historical_endpoint_stable_identity
    historical_frame_commit_immutable_update historical_observation_frame_commit
    historical_calibration_receipt_immutable_update historical_calibration_receipt
    historical_disabled_calibration_receipt_immutable_update historical_disabled_calibration_receipt
    historical_baseline_checkpoint_immutable_update historical_observation_baseline_checkpoint
    historical_projection_work_immutable_update historical_projection_work
    historical_projection_immutable_update historical_finding_projection
    historical_projection_checkpoint_immutable_update historical_projection_checkpoint
    historical_finding_immutable_update historical_finding
    historical_rank_immutable_update historical_finding_positive_rank
    historical_reason_count_immutable_update historical_finding_reason_count
    historical_retraction_immutable_update historical_finding_retraction
)
for (( index = 1; index <= ${#immutable_mappings}; index += 2 )); do
    trigger=${immutable_mappings[index]}
    table=${immutable_mappings[index + 1]}
    sqlite3 -bail "$working_database" \
        "CREATE TRIGGER $trigger BEFORE UPDATE ON $table BEGIN SELECT RAISE(ABORT, 'immutable historical evidence'); END;"
done

schema_digest_tool="$temporary_root/schema-digest.swift"
cat >"$schema_digest_tool" <<'SWIFT'
import CryptoKit
import Foundation
import SQLite3

let path = CommandLine.arguments[1]
var database: OpaquePointer?
guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database else { exit(2) }
defer { sqlite3_close_v2(database) }
var statement: OpaquePointer?
let sql = "SELECT type,name,tbl_name,sql FROM sqlite_schema WHERE type IN ('table','index','trigger') AND name NOT LIKE 'sqlite_%'"
guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement else { exit(2) }
defer { sqlite3_finalize(statement) }
struct Object { let type: Data; let name: Data; let table: Data; let sql: Data? }
func data(_ column: Int32) -> Data {
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
    return Data(bytes: bytes, count: count)
}
var objects: [Object] = []
while sqlite3_step(statement) == SQLITE_ROW {
    objects.append(Object(
        type: data(0), name: data(1), table: data(2),
        sql: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : data(3)
    ))
}
objects.sort { lhs, rhs in
    for pair in [(lhs.type,rhs.type),(lhs.name,rhs.name),(lhs.table,rhs.table)] {
        if pair.0 != pair.1 { return pair.0.lexicographicallyPrecedes(pair.1) }
    }
    return false
}
func append(_ value: Data, to output: inout Data) {
    var count = UInt64(value.count).bigEndian
    withUnsafeBytes(of: &count) { output.append(contentsOf: $0) }
    output.append(value)
}
var canonical = Data()
append(Data("SpaceTrace.SQLite.schema-object-digest.v1".utf8), to: &canonical)
for object in objects {
    append(object.type, to: &canonical)
    append(object.name, to: &canonical)
    append(object.table, to: &canonical)
    if let sql = object.sql { canonical.append(0); append(sql, to: &canonical) }
    else { canonical.append(0xff) }
}
print(SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined())
SWIFT
installed_schema_digest=$(swift -module-cache-path "$temporary_root/module-cache" \
    "$schema_digest_tool" "$working_database")
[[ "$installed_schema_digest" == 38821bf16852476d4457a4921462257b5b194a1fe5703de02d1ee4f8c63e5371 ]] || {
    echo "generated v11 schema differs from the repository digest: $installed_schema_digest" >&2
    exit 68
}

sqlite3 -bail "$working_database" <<'SQL'
PRAGMA foreign_keys=ON;
BEGIN IMMEDIATE;
INSERT INTO historical_store_identity(singleton,format_version,store_generation)
VALUES(1,1,X'00112233445566778899aabbccddeeff');
UPDATE historical_retention_policy SET updated_at_ms=2000000000000 WHERE singleton=1;
INSERT INTO historical_scope(scope_key,scope_id)
VALUES(1,X'72656c65617365642d7631312d73636f7065');
INSERT INTO historical_subject(subject_key,scope_key,subject_id,identity_basis)
VALUES
    (1,1,X'72656c65617365642d7631312d726f6f74',1),
    (2,1,X'72656c65617365642d7631312d6368696c64',1);
INSERT INTO historical_location(
    location_key,scope_key,path_semantics_version,location_id,path_utf8,
    display_name_utf8
) VALUES
    (1,1,1,X'72656c65617365642d7631312d726f6f742d6c6f636174696f6e',
     X'2f46697874757265732f52656c6561736564563131',X'52656c6561736564563131'),
    (2,1,1,X'72656c65617365642d7631312d6368696c642d6c6f636174696f6e',
     X'2f46697874757265732f52656c65617365645631312f4368696c64',X'4368696c64');
INSERT INTO frozen_attribution_decision(
    decision_id,format_version,canonical_payload,canonical_sha256,
    catalog_version,decision_kind,
    category_code,confidence_code,rule_id,rule_version,evidence_code
) VALUES(
    1,1,
    X'7b22636174616c6f6756657273696f6e223a312c22726573756c74223a7b226b696e64223a22756e6b6e6f776e222c22726561736f6e223a7b226b696e64223a226e6f5f6d61746368696e675f72756c65227d7d7d',
    X'e367123ab8d3c76c4f8e895421e7661528902acf35989dba751a82ac2c0fe7a1',
    1,2,NULL,NULL,NULL,NULL,NULL
);
INSERT INTO scan_run(
    id,stream_id,region_path,dirty_revision_be,state,coverage,entries_seen,
    directories_staged,started_at_ms,finished_at_ms
) VALUES(
    'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee','released-v11-stream',
    '/Fixtures/ReleasedV11',X'0000000000000002','completed','complete',2,2,
    2000000010000,2000000010200
);
INSERT INTO historical_observation_batch(
    batch_id,scan_run_id,stream_id_utf8,scope_key,root_subject_key,volume_id,
    mount_generation_id,coverage_epoch_id,path_semantics_version,
    measurement_semantics_version,created_at_ms
) VALUES(
    1,'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',X'72656c65617365642d7631312d73747265616d',
    1,1,X'72656c65617365642d7631312d766f6c756d65',
    X'72656c65617365642d7631312d6d6f756e74',
    X'72656c65617365642d7631312d65706f6368',1,1,2000000010200
);
INSERT INTO historical_observation_frame(frame_id,batch_id,metric)
VALUES(101,1,1),(102,1,2);
INSERT INTO historical_observation_node(
    node_id,batch_id,subject_key,location_key,parent_node_id,observed_at_ms,
    direct_children_coverage,classification_decision_id
) VALUES
    (1001,1,1,1,NULL,2000000010100,1,1),
    (1002,1,2,2,1001,2000000010101,1,1);
INSERT INTO historical_metric_endpoint(
    node_id,metric,frame_id,state_kind,bytes,measurement_coverage,unknown_reason_code
) VALUES
    (1001,1,101,1,4096,1,NULL),(1001,2,102,1,8192,1,NULL),
    (1002,1,101,1,1024,1,NULL),(1002,2,102,1,4096,1,NULL);
INSERT INTO historical_endpoint_stable_identity(
    node_id,guard_kind,generation_token_utf8,birth_seconds,birth_nanoseconds,
    node_kind,link_status
) VALUES
    (1001,1,X'72656c65617365642d726f6f742d746f6b656e',NULL,NULL,1,1),
    (1002,1,X'72656c65617365642d6368696c642d746f6b656e',NULL,NULL,1,1);
INSERT INTO historical_observation_frame_commit(
    sequence,frame_id,root_node_id,root_metric,endpoint_count,committed_at_ms,
    retention_anchor_ms,expires_at_ms
) VALUES
    (1,101,1001,1,2,2000000010200,2000000010100,2002592010100),
    (2,102,1001,2,2,2000000010200,2000000010100,2002592010100);
INSERT INTO historical_calibration_receipt(
    scan_run_id,request_format_version,canonical_request_sha256,outcome,
    logical_sequence,allocated_sequence,committed_at_ms,retention_anchor_ms,
    expires_at_ms
) VALUES(
    'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',1,
    X'2020202020202020202020202020202020202020202020202020202020202020',
    1,1,2,2000000010200,2000000010100,2002592010100
);
INSERT INTO historical_observation_baseline_checkpoint(
    frame_sequence,checkpoint_kind,committed_at_ms
) VALUES(1,1,2000000010200),(2,1,2000000010200);
INSERT INTO schema_migration(version,applied_at_ms,checksum)
VALUES(11,2000000000011,'38821bf16852476d4457a4921462257b5b194a1fe5703de02d1ee4f8c63e5371');
PRAGMA user_version=11;
COMMIT;
SQL
sqlite3 -bail "$working_database" 'PRAGMA journal_mode=DELETE; VACUUM;'
sqlite3 -bail "$working_database" 'PRAGMA journal_mode=WAL;'
sqlite3 -bail "$working_database" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null
sqlite3 -bail "$working_database" 'PRAGMA journal_mode=DELETE;' >/dev/null

[[ $(sqlite3 -readonly "$working_database" 'PRAGMA quick_check') == ok ]] || {
    echo "v11 fixture quick_check failed" >&2
    exit 68
}
[[ -z $(sqlite3 -readonly "$working_database" 'PRAGMA foreign_key_check') ]] || {
    echo "v11 fixture foreign_key_check failed" >&2
    exit 68
}
[[ $(sqlite3 -readonly "$working_database" 'PRAGMA user_version') == 11 ]] || {
    echo "v11 fixture has the wrong schema version" >&2
    exit 68
}

mkdir -p "${output_path:h}"
temporary_output="${output_path}.tmp.$$"
cp "$working_database" "$temporary_output"
chmod 0644 "$temporary_output"
mv -f "$temporary_output" "$output_path"
printf 'schemaVersion=11\ngeneratorVersion=%s\nseed=%s\nsha256=%s\n' \
    "$generator_version" "$expected_seed" \
    "$(shasum -a 256 "$output_path" | awk '{print $1}')"
