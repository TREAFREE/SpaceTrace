import Foundation
import Darwin
import SQLite3

@_spi(Benchmark)
public enum SQLiteHistoricalPrototypeScenario: String, Sendable, Codable, CaseIterable {
    case noChange = "no-change"
    case highFrameCount = "high-frame-count"
    case allStableIdentity = "all-stable-identity"
    case twoPercentChurn = "two-percent-churn"
    case legacyOverlap = "v10-v11-overlap"
}

@_spi(Benchmark)
public struct SQLiteHistoricalPrototypeObjectSize: Sendable, Codable, Equatable {
    public let name: String
    public let bytes: Int64
}

@_spi(Benchmark)
public struct SQLiteHistoricalPrototypeResult: Sendable, Codable, Equatable {
    public let scenario: SQLiteHistoricalPrototypeScenario
    public let requestedDirectorySamples: Int
    public let retainedV11Nodes: Int
    public let removedV11Nodes: Int
    public let retainedLegacyRows: Int
    public let findingCount: Int
    public let scopeCount: Int
    public let subjectCount: Int
    public let locationCount: Int
    public let preMaintenanceBytes: Int64
    public let mainDatabaseBytes: Int64
    public let walBytes: Int64
    public let shmBytes: Int64
    public let checkpointedBytes: Int64
    public let peakResidentBytes: Int64
    public let insertionMilliseconds: Double
    public let retentionMilliseconds: Double
    public let maintenanceMilliseconds: Double
    public let integrityCheck: String
    public let foreignKeyViolationCount: Int
    public let secureDeleteEnabled: Bool
    public let objectSizes: [SQLiteHistoricalPrototypeObjectSize]
    public let queryPlans: [String]
}

/// Provisional schema-v11 physical layout.
///
/// This surface is deliberately narrow while the size and query-plan evidence
/// is being collected. Migration must not consume it until Task 2 freezes the
/// complete schema digest and the released one-million-sample workload passes.
@_spi(Benchmark)
public enum SQLiteHistoricalFindingSchema {
    static let prototypeObjectNames: Set<String> = Set(
        prototypeTableNames + prototypeIndexNames + prototypeTriggerNames
    )

    /// Exact v11 object manifest. This intentionally includes the supporting
    /// index added to the existing `node_current` table.
    static let frozenObjectNames = prototypeObjectNames

    /// SHA-256 over the exact v11 `sqlite_schema` object graph plus the legacy
    /// schema it extends. The codec defines the canonical byte framing.
    static let frozenSchemaDigest = Data([
        0x9A, 0x48, 0x40, 0xB4, 0x0E, 0x7C, 0x73, 0x18,
        0x37, 0x22, 0x84, 0x7C, 0xF9, 0x86, 0x85, 0x18,
        0x61, 0x97, 0x8C, 0x59, 0x34, 0x18, 0xD7, 0x91,
        0x0B, 0x02, 0xB2, 0x05, 0xC7, 0xEF, 0xE9, 0x91,
    ])

    static func installPrototype(on database: OpaquePointer) throws {
        try execute(database, "PRAGMA foreign_keys=ON")
        try execute(database, schemaSQL)
    }

    static func installFrozenV11(on database: OpaquePointer) throws {
        try installPrototype(on: database)
    }

    /// Runs the checked-in physical prototype without exposing SQL or a
    /// connection handle to the benchmark executable.
    @_spi(Benchmark)
    public static func runPrototype(
        databaseURL: URL,
        directorySamples: Int,
        scenario: SQLiteHistoricalPrototypeScenario
    ) throws -> SQLiteHistoricalPrototypeResult {
        guard directorySamples > 0, directorySamples.isMultiple(of: 25) else {
            throw SQLiteHistoricalFindingSchemaError.invalidDirectorySampleCount
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE,
            nil
        ) == SQLITE_OK, let database else {
            throw SQLiteHistoricalFindingSchemaError.sqlite("open prototype database")
        }
        defer { sqlite3_close_v2(database) }

        try execute(
            database,
            "PRAGMA foreign_keys=ON; PRAGMA secure_delete=ON; PRAGMA cache_size=-8192; PRAGMA temp_store=FILE; PRAGMA mmap_size=0; PRAGMA auto_vacuum=FULL; VACUUM; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;"
        )
        if try querySingleInt(
            database,
            "SELECT count(*) FROM sqlite_schema WHERE type='table' AND name='historical_store_identity'"
        ) == 0 {
            try installPrototype(on: database)
        }
        let started = ContinuousClock.now
        let counts = try seedPrototype(
            database,
            directorySamples: directorySamples,
            scenario: scenario
        )
        let insertionMilliseconds = elapsedMilliseconds(since: started)
        let preMaintenanceBytes = try databaseBytes(databaseURL)

        let retentionStarted = ContinuousClock.now
        try retainPrototypeWindow(database, expiredBatchIDs: counts.expiredBatchIDs)
        let retentionMilliseconds = elapsedMilliseconds(since: retentionStarted)

        let maintenanceStarted = ContinuousClock.now
        try execute(database, "PRAGMA wal_checkpoint(TRUNCATE)")
        let maintenanceMilliseconds = elapsedMilliseconds(since: maintenanceStarted)

        let objectSizes = try prototypeObjectSizes(database)
        let integrity = try querySingleText(database, "PRAGMA integrity_check")
        let foreignKeyViolationCount = try queryRowCount(database, "PRAGMA foreign_key_check")
        let retainedV11Nodes = try querySingleInt(
            database,
            "SELECT count(*) FROM historical_observation_node"
        )
        let retainedLegacyRows = try querySingleInt(
            database,
            "SELECT count(*) FROM directory_history_sample"
        )
        let findingCount = try querySingleInt(database, "SELECT count(*) FROM historical_finding")
        let locationCount = try querySingleInt(database, "SELECT count(*) FROM historical_location")
        let componentBytes = try databaseComponentBytes(databaseURL)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return SQLiteHistoricalPrototypeResult(
            scenario: scenario,
            requestedDirectorySamples: directorySamples,
            retainedV11Nodes: retainedV11Nodes,
            removedV11Nodes: counts.insertedNodeCount - retainedV11Nodes,
            retainedLegacyRows: retainedLegacyRows,
            findingCount: findingCount,
            scopeCount: counts.scopeCount,
            subjectCount: counts.subjectCount,
            locationCount: locationCount,
            preMaintenanceBytes: preMaintenanceBytes,
            mainDatabaseBytes: componentBytes.main,
            walBytes: componentBytes.wal,
            shmBytes: componentBytes.shm,
            checkpointedBytes: componentBytes.main + componentBytes.wal + componentBytes.shm,
            peakResidentBytes: Int64(usage.ru_maxrss),
            insertionMilliseconds: insertionMilliseconds,
            retentionMilliseconds: retentionMilliseconds,
            maintenanceMilliseconds: maintenanceMilliseconds,
            integrityCheck: integrity,
            foreignKeyViolationCount: foreignKeyViolationCount,
            secureDeleteEnabled: try querySingleInt(database, "PRAGMA secure_delete") == 1,
            objectSizes: objectSizes,
            queryPlans: try prototypeQueryPlans(database)
        )
    }

    private static let prototypeTableNames = [
        "historical_store_identity",
        "historical_scope",
        "historical_retention_policy",
        "historical_subject",
        "historical_location",
        "frozen_attribution_decision",
        "frozen_attribution_competitor",
        "historical_observation_batch",
        "historical_observation_frame",
        "historical_observation_node",
        "historical_metric_endpoint",
        "historical_endpoint_stable_identity",
        "historical_observation_frame_commit",
        "historical_calibration_receipt",
        "historical_disabled_calibration_receipt",
        "historical_observation_baseline_checkpoint",
        "historical_projection_work",
        "historical_finding_projection",
        "historical_projection_checkpoint",
        "historical_finding",
        "historical_finding_positive_rank",
        "historical_finding_reason_count",
        "historical_finding_retraction",
        "historical_path_free_gap",
    ]

    private static let prototypeIndexNames = [
        "historical_batch_scope",
        "historical_batch_root_subject",
        "historical_node_subject",
        "historical_node_location",
        "historical_node_parent",
        "historical_node_classification_decision",
        "historical_metric_endpoint_frame",
        "historical_frame_commit_root_endpoint",
        "node_current_last_scan_run",
        "historical_projection_work_baseline",
        "historical_finding_baseline_endpoint",
        "historical_finding_comparison_endpoint",
        "historical_finding_movement_ancestor",
    ]

    private static let prototypeTriggerNames = [
        "historical_node_validate_insert",
        "historical_metric_endpoint_validate_insert",
        "historical_stable_identity_validate_insert",
        "historical_frame_commit_validate",
        "historical_calibration_receipt_validate",
        "historical_disabled_calibration_receipt_validate",
        "historical_baseline_validate_series",
        "historical_work_validate_pair",
        "historical_finding_validate_insert",
        "historical_rank_validate_projection",
        "historical_retraction_validate_target",
        "historical_store_identity_immutable_update",
        "historical_scope_immutable_update",
        "historical_subject_immutable_update",
        "historical_location_immutable_update",
        "historical_attribution_decision_immutable_update",
        "historical_attribution_competitor_immutable_update",
        "historical_batch_immutable_update",
        "historical_frame_immutable_update",
        "historical_node_immutable_update",
        "historical_metric_endpoint_immutable_update",
        "historical_stable_identity_immutable_update",
        "historical_frame_commit_immutable_update",
        "historical_calibration_receipt_immutable_update",
        "historical_disabled_calibration_receipt_immutable_update",
        "historical_baseline_checkpoint_immutable_update",
        "historical_projection_work_immutable_update",
        "historical_projection_immutable_update",
        "historical_projection_checkpoint_immutable_update",
        "historical_finding_immutable_update",
        "historical_rank_immutable_update",
        "historical_reason_count_immutable_update",
        "historical_retraction_immutable_update",
    ]

    private static let schemaSQL = #"""
    CREATE TABLE historical_store_identity (
        singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
        format_version INTEGER NOT NULL CHECK(format_version = 1),
        store_generation BLOB NOT NULL CHECK(
            typeof(store_generation) = 'blob' AND length(store_generation) = 16
            AND store_generation != zeroblob(16)
        )
    ) WITHOUT ROWID;

    CREATE TABLE historical_scope (
        scope_key INTEGER PRIMARY KEY,
        scope_id BLOB NOT NULL UNIQUE CHECK(
            typeof(scope_id) = 'blob' AND length(scope_id) BETWEEN 1 AND 4096
        )
    );

    CREATE TABLE historical_retention_policy (
        singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
        path_history_days INTEGER NOT NULL CHECK(path_history_days BETWEEN 0 AND 30),
        updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0)
    ) WITHOUT ROWID;
    INSERT INTO historical_retention_policy VALUES(1, 30, 0);

    CREATE TABLE historical_subject (
        subject_key INTEGER PRIMARY KEY,
        scope_key INTEGER NOT NULL REFERENCES historical_scope(scope_key) ON DELETE RESTRICT,
        identity_basis INTEGER NOT NULL CHECK(identity_basis IN (1, 2)),
        subject_id BLOB NOT NULL CHECK(
            typeof(subject_id) = 'blob' AND length(subject_id) BETWEEN 1 AND 4096
        ),
        UNIQUE(scope_key, identity_basis, subject_id)
    );

    CREATE TABLE historical_location (
        location_key INTEGER PRIMARY KEY,
        scope_key INTEGER NOT NULL REFERENCES historical_scope(scope_key) ON DELETE RESTRICT,
        path_semantics_version INTEGER NOT NULL CHECK(path_semantics_version > 0),
        location_id BLOB NOT NULL CHECK(
            typeof(location_id) = 'blob' AND length(location_id) BETWEEN 1 AND 4096
        ),
        path_utf8 BLOB NOT NULL CHECK(
            typeof(path_utf8) = 'blob' AND length(path_utf8) BETWEEN 1 AND 4096
            AND substr(path_utf8, 1, 1) = X'2F' AND instr(path_utf8, X'00') = 0
        ),
        display_name_utf8 BLOB NOT NULL CHECK(
            typeof(display_name_utf8) = 'blob' AND length(display_name_utf8) BETWEEN 1 AND 1024
            AND instr(display_name_utf8, X'00') = 0 AND instr(display_name_utf8, X'2F') = 0
        ),
        UNIQUE(scope_key, path_semantics_version, location_id)
    );

    CREATE TABLE frozen_attribution_decision (
        decision_id INTEGER PRIMARY KEY,
        format_version INTEGER NOT NULL CHECK(format_version = 1),
        canonical_payload BLOB NOT NULL CHECK(
            typeof(canonical_payload) = 'blob' AND length(canonical_payload) BETWEEN 1 AND 65536
        ),
        canonical_sha256 BLOB NOT NULL UNIQUE CHECK(
            typeof(canonical_sha256) = 'blob' AND length(canonical_sha256) = 32
        ),
        catalog_version INTEGER NOT NULL CHECK(catalog_version > 0),
        decision_kind INTEGER NOT NULL CHECK(decision_kind IN (1, 2, 3)),
        category_code INTEGER CHECK(category_code IS NULL OR category_code BETWEEN 1 AND 8),
        confidence_code INTEGER CHECK(confidence_code IS NULL OR confidence_code BETWEEN 1 AND 3),
        rule_id BLOB,
        rule_version INTEGER,
        evidence_code BLOB,
        CHECK(
            (decision_kind = 1 AND category_code IS NOT NULL AND confidence_code IS NOT NULL
                AND typeof(rule_id) = 'blob' AND length(rule_id) BETWEEN 1 AND 1024
                AND rule_version > 0 AND typeof(evidence_code) = 'blob'
                AND length(evidence_code) BETWEEN 1 AND 1024)
            OR
            (decision_kind IN (2, 3) AND category_code IS NULL AND confidence_code IS NULL
                AND rule_id IS NULL AND rule_version IS NULL AND evidence_code IS NULL)
        )
    );

    CREATE TABLE frozen_attribution_competitor (
        decision_id INTEGER NOT NULL REFERENCES frozen_attribution_decision(decision_id) ON DELETE CASCADE,
        ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
        rule_id BLOB NOT NULL CHECK(typeof(rule_id) = 'blob' AND length(rule_id) BETWEEN 1 AND 1024),
        PRIMARY KEY(decision_id, ordinal),
        UNIQUE(decision_id, rule_id)
    ) WITHOUT ROWID;

    CREATE TABLE historical_observation_batch (
        batch_id INTEGER PRIMARY KEY AUTOINCREMENT,
        scan_run_id TEXT NOT NULL UNIQUE REFERENCES scan_run(id) ON DELETE RESTRICT,
        stream_id_utf8 BLOB NOT NULL CHECK(typeof(stream_id_utf8) = 'blob' AND length(stream_id_utf8) BETWEEN 1 AND 4096),
        scope_key INTEGER NOT NULL REFERENCES historical_scope(scope_key) ON DELETE RESTRICT,
        root_subject_key INTEGER NOT NULL REFERENCES historical_subject(subject_key) ON DELETE RESTRICT,
        volume_id BLOB NOT NULL CHECK(typeof(volume_id) = 'blob' AND length(volume_id) BETWEEN 1 AND 4096),
        mount_generation_id BLOB NOT NULL CHECK(typeof(mount_generation_id) = 'blob' AND length(mount_generation_id) BETWEEN 1 AND 4096),
        coverage_epoch_id BLOB NOT NULL CHECK(typeof(coverage_epoch_id) = 'blob' AND length(coverage_epoch_id) BETWEEN 1 AND 4096),
        path_semantics_version INTEGER NOT NULL CHECK(path_semantics_version > 0),
        measurement_semantics_version INTEGER NOT NULL CHECK(measurement_semantics_version > 0),
        created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0)
    );

    CREATE TABLE historical_observation_frame (
        frame_id INTEGER PRIMARY KEY,
        batch_id INTEGER NOT NULL REFERENCES historical_observation_batch(batch_id) ON DELETE RESTRICT,
        metric INTEGER NOT NULL CHECK(metric IN (1, 2)),
        UNIQUE(batch_id, metric)
    );

    CREATE TABLE historical_observation_node (
        node_id INTEGER PRIMARY KEY AUTOINCREMENT,
        batch_id INTEGER NOT NULL REFERENCES historical_observation_batch(batch_id) ON DELETE RESTRICT,
        subject_key INTEGER NOT NULL REFERENCES historical_subject(subject_key) ON DELETE RESTRICT,
        location_key INTEGER NOT NULL REFERENCES historical_location(location_key) ON DELETE RESTRICT,
        parent_node_id INTEGER REFERENCES historical_observation_node(node_id) DEFERRABLE INITIALLY DEFERRED,
        observed_at_ms INTEGER NOT NULL CHECK(observed_at_ms >= 0),
        direct_children_coverage INTEGER NOT NULL CHECK(direct_children_coverage IN (1, 2, 3)),
        classification_decision_id INTEGER REFERENCES frozen_attribution_decision(decision_id) ON DELETE RESTRICT,
        UNIQUE(batch_id, subject_key),
        UNIQUE(batch_id, location_key)
    );

    CREATE TABLE historical_metric_endpoint (
        node_id INTEGER NOT NULL REFERENCES historical_observation_node(node_id) ON DELETE RESTRICT,
        metric INTEGER NOT NULL CHECK(metric IN (1, 2)),
        frame_id INTEGER NOT NULL REFERENCES historical_observation_frame(frame_id) ON DELETE RESTRICT,
        state_kind INTEGER NOT NULL CHECK(state_kind IN (1, 2, 3)),
        bytes INTEGER CHECK(bytes IS NULL OR bytes >= 0),
        measurement_coverage INTEGER CHECK(measurement_coverage IN (1, 2)),
        unknown_reason_code INTEGER CHECK(unknown_reason_code IS NULL OR unknown_reason_code BETWEEN 1 AND 6),
        PRIMARY KEY(node_id, metric),
        CHECK(
            (state_kind = 1 AND bytes IS NOT NULL AND measurement_coverage IS NOT NULL AND unknown_reason_code IS NULL)
            OR (state_kind = 2 AND bytes IS NULL AND measurement_coverage IS NULL AND unknown_reason_code IS NULL)
            OR (state_kind = 3 AND bytes IS NULL AND measurement_coverage IS NULL AND unknown_reason_code IS NOT NULL)
        )
    ) WITHOUT ROWID;

    CREATE TABLE historical_endpoint_stable_identity (
        node_id INTEGER PRIMARY KEY REFERENCES historical_observation_node(node_id) ON DELETE RESTRICT,
        guard_kind INTEGER NOT NULL CHECK(guard_kind IN (1, 2)),
        generation_token_utf8 BLOB,
        birth_seconds INTEGER,
        birth_nanoseconds INTEGER,
        node_kind INTEGER NOT NULL CHECK(node_kind = 1),
        link_status INTEGER NOT NULL CHECK(link_status IN (1, 2, 3)),
        CHECK(
            (guard_kind = 1 AND typeof(generation_token_utf8) = 'blob'
                AND length(generation_token_utf8) BETWEEN 1 AND 4096
                AND birth_seconds IS NULL AND birth_nanoseconds IS NULL)
            OR (guard_kind = 2 AND generation_token_utf8 IS NULL
                AND birth_seconds >= 0 AND birth_nanoseconds BETWEEN 0 AND 999999999)
        )
    ) WITHOUT ROWID;

    CREATE TABLE historical_observation_frame_commit (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        frame_id INTEGER NOT NULL UNIQUE REFERENCES historical_observation_frame(frame_id) ON DELETE RESTRICT,
        root_node_id INTEGER NOT NULL,
        root_metric INTEGER NOT NULL CHECK(root_metric IN (1, 2)),
        endpoint_count INTEGER NOT NULL CHECK(endpoint_count > 0),
        committed_at_ms INTEGER NOT NULL CHECK(committed_at_ms >= 0),
        retention_anchor_ms INTEGER NOT NULL CHECK(retention_anchor_ms BETWEEN 0 AND 9223372034262775807),
        expires_at_ms INTEGER NOT NULL,
        CHECK(expires_at_ms = retention_anchor_ms + 2592000000),
        FOREIGN KEY(root_node_id, root_metric) REFERENCES historical_metric_endpoint(node_id, metric) ON DELETE RESTRICT
    );

    CREATE TABLE historical_calibration_receipt (
        scan_run_id TEXT PRIMARY KEY REFERENCES scan_run(id) ON DELETE RESTRICT,
        request_format_version INTEGER NOT NULL CHECK(request_format_version = 1),
        canonical_request_sha256 BLOB NOT NULL CHECK(typeof(canonical_request_sha256) = 'blob' AND length(canonical_request_sha256) = 32),
        outcome INTEGER NOT NULL CHECK(outcome IN (1, 2)),
        logical_sequence INTEGER UNIQUE REFERENCES historical_observation_frame_commit(sequence) ON DELETE RESTRICT,
        allocated_sequence INTEGER UNIQUE REFERENCES historical_observation_frame_commit(sequence) ON DELETE RESTRICT,
        committed_at_ms INTEGER NOT NULL CHECK(committed_at_ms >= 0),
        retention_anchor_ms INTEGER NOT NULL CHECK(retention_anchor_ms >= 0),
        expires_at_ms INTEGER NOT NULL CHECK(expires_at_ms >= 0),
        CHECK(
            (outcome = 1 AND logical_sequence IS NOT NULL AND allocated_sequence = logical_sequence + 1
                AND retention_anchor_ms <= 9223372034262775807
                AND expires_at_ms = retention_anchor_ms + 2592000000)
            OR (outcome = 2 AND logical_sequence IS NULL AND allocated_sequence IS NULL
                AND retention_anchor_ms = committed_at_ms
                AND retention_anchor_ms <= 9223372036249975807
                AND expires_at_ms = retention_anchor_ms + 604800000)
        )
    ) WITHOUT ROWID;

    CREATE TABLE historical_disabled_calibration_receipt (
        receipt_id BLOB PRIMARY KEY CHECK(typeof(receipt_id) = 'blob' AND length(receipt_id) = 16),
        request_format_version INTEGER NOT NULL CHECK(request_format_version = 1),
        canonical_request_sha256 BLOB NOT NULL CHECK(typeof(canonical_request_sha256) = 'blob' AND length(canonical_request_sha256) = 32),
        committed_at_ms INTEGER NOT NULL CHECK(committed_at_ms BETWEEN 0 AND 9223372036249975807),
        expires_at_ms INTEGER NOT NULL CHECK(expires_at_ms = committed_at_ms + 604800000)
    ) WITHOUT ROWID;

    CREATE TABLE historical_observation_baseline_checkpoint (
        frame_sequence INTEGER PRIMARY KEY REFERENCES historical_observation_frame_commit(sequence) ON DELETE RESTRICT,
        checkpoint_kind INTEGER NOT NULL CHECK(checkpoint_kind IN (1, 2)),
        committed_at_ms INTEGER NOT NULL CHECK(committed_at_ms >= 0)
    );

    CREATE TABLE historical_projection_work (
        work_id INTEGER PRIMARY KEY AUTOINCREMENT,
        baseline_sequence INTEGER NOT NULL REFERENCES historical_observation_frame_commit(sequence) ON DELETE RESTRICT,
        comparison_sequence INTEGER NOT NULL UNIQUE REFERENCES historical_observation_frame_commit(sequence) ON DELETE RESTRICT,
        algorithm_version INTEGER NOT NULL CHECK(algorithm_version = 1),
        ranking_policy_version INTEGER NOT NULL CHECK(ranking_policy_version = 1),
        positive_limit INTEGER NOT NULL CHECK(positive_limit BETWEEN 1 AND 100),
        created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
        CHECK(comparison_sequence > baseline_sequence)
    );

    CREATE TABLE historical_finding_projection (
        projection_id INTEGER PRIMARY KEY AUTOINCREMENT,
        work_id INTEGER NOT NULL UNIQUE REFERENCES historical_projection_work(work_id) ON DELETE RESTRICT,
        format_version INTEGER NOT NULL CHECK(format_version = 1),
        canonical_result_sha256 BLOB NOT NULL CHECK(typeof(canonical_result_sha256) = 'blob' AND length(canonical_result_sha256) = 32),
        truncated_positive_count INTEGER NOT NULL CHECK(truncated_positive_count >= 0),
        committed_at_ms INTEGER NOT NULL CHECK(committed_at_ms >= 0)
    );

    CREATE TABLE historical_projection_checkpoint (
        work_id INTEGER PRIMARY KEY,
        committed_at_ms INTEGER NOT NULL CHECK(committed_at_ms >= 0),
        FOREIGN KEY(work_id) REFERENCES historical_projection_work(work_id) ON DELETE RESTRICT,
        FOREIGN KEY(work_id) REFERENCES historical_finding_projection(work_id) ON DELETE RESTRICT
    );

    CREATE TABLE historical_finding (
        finding_id INTEGER PRIMARY KEY AUTOINCREMENT,
        projection_id INTEGER NOT NULL REFERENCES historical_finding_projection(projection_id) ON DELETE RESTRICT,
        ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
        finding_key_sha256 BLOB NOT NULL UNIQUE CHECK(typeof(finding_key_sha256) = 'blob' AND length(finding_key_sha256) = 32),
        draft_sha256 BLOB NOT NULL CHECK(typeof(draft_sha256) = 'blob' AND length(draft_sha256) = 32),
        baseline_node_id INTEGER NOT NULL,
        baseline_metric INTEGER NOT NULL CHECK(baseline_metric IN (1, 2)),
        comparison_node_id INTEGER NOT NULL,
        comparison_metric INTEGER NOT NULL CHECK(comparison_metric IN (1, 2)),
        kind INTEGER NOT NULL CHECK(kind BETWEEN 1 AND 5),
        inclusive_delta_bytes INTEGER NOT NULL,
        ranking_contribution_bytes INTEGER,
        movement_ancestor_finding_id INTEGER REFERENCES historical_finding(finding_id) DEFERRABLE INITIALLY DEFERRED,
        expires_at_ms INTEGER NOT NULL,
        UNIQUE(projection_id, ordinal),
        CHECK(baseline_metric = comparison_metric),
        CHECK(baseline_node_id != comparison_node_id),
        FOREIGN KEY(baseline_node_id, baseline_metric) REFERENCES historical_metric_endpoint(node_id, metric) ON DELETE RESTRICT,
        FOREIGN KEY(comparison_node_id, comparison_metric) REFERENCES historical_metric_endpoint(node_id, metric) ON DELETE RESTRICT
    );

    CREATE TABLE historical_finding_positive_rank (
        projection_id INTEGER NOT NULL REFERENCES historical_finding_projection(projection_id) ON DELETE CASCADE,
        rank INTEGER NOT NULL CHECK(rank BETWEEN 1 AND 100),
        finding_id INTEGER NOT NULL UNIQUE REFERENCES historical_finding(finding_id) ON DELETE CASCADE,
        PRIMARY KEY(projection_id, rank)
    ) WITHOUT ROWID;

    CREATE TABLE historical_finding_reason_count (
        projection_id INTEGER NOT NULL REFERENCES historical_finding_projection(projection_id) ON DELETE CASCADE,
        category INTEGER NOT NULL CHECK(category BETWEEN 1 AND 3),
        reason_code INTEGER NOT NULL CHECK(
            (category = 1 AND reason_code BETWEEN 1 AND 30)
            OR (category = 2 AND reason_code BETWEEN 31 AND 34)
            OR (category = 3 AND reason_code BETWEEN 35 AND 38)
        ),
        count INTEGER NOT NULL CHECK(count > 0),
        PRIMARY KEY(projection_id, category, reason_code)
    ) WITHOUT ROWID;

    CREATE TABLE historical_finding_retraction (
        retraction_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        request_format_version INTEGER NOT NULL CHECK(request_format_version = 1),
        request_id BLOB NOT NULL UNIQUE CHECK(typeof(request_id) = 'blob' AND length(request_id) = 16),
        canonical_request_sha256 BLOB NOT NULL CHECK(typeof(canonical_request_sha256) = 'blob' AND length(canonical_request_sha256) = 32),
        retracted_finding_id INTEGER NOT NULL UNIQUE REFERENCES historical_finding(finding_id) ON DELETE RESTRICT,
        expected_draft_sha256 BLOB NOT NULL CHECK(typeof(expected_draft_sha256) = 'blob' AND length(expected_draft_sha256) = 32),
        reason_code INTEGER NOT NULL CHECK(reason_code = 1),
        committed_at_ms INTEGER NOT NULL CHECK(committed_at_ms >= 0)
    );

    CREATE TABLE historical_path_free_gap (
        reason_code INTEGER PRIMARY KEY CHECK(reason_code BETWEEN 1 AND 3),
        first_recorded_at_ms INTEGER NOT NULL CHECK(first_recorded_at_ms >= 0),
        last_recorded_at_ms INTEGER NOT NULL CHECK(last_recorded_at_ms >= first_recorded_at_ms),
        occurrence_count INTEGER NOT NULL CHECK(occurrence_count > 0)
    ) WITHOUT ROWID;

    CREATE INDEX historical_batch_scope ON historical_observation_batch(scope_key, batch_id);
    CREATE INDEX historical_batch_root_subject ON historical_observation_batch(root_subject_key);
    CREATE INDEX historical_node_subject ON historical_observation_node(subject_key);
    CREATE INDEX historical_node_location ON historical_observation_node(location_key);
    CREATE INDEX historical_node_parent ON historical_observation_node(parent_node_id) WHERE parent_node_id IS NOT NULL;
    CREATE INDEX historical_node_classification_decision ON historical_observation_node(classification_decision_id) WHERE classification_decision_id IS NOT NULL;
    CREATE INDEX historical_metric_endpoint_frame ON historical_metric_endpoint(frame_id, node_id);
    CREATE INDEX historical_frame_commit_root_endpoint ON historical_observation_frame_commit(root_node_id, root_metric);
    CREATE INDEX node_current_last_scan_run ON node_current(last_scan_run_id);
    CREATE INDEX historical_projection_work_baseline ON historical_projection_work(baseline_sequence);
    CREATE INDEX historical_finding_baseline_endpoint ON historical_finding(baseline_node_id, baseline_metric);
    CREATE INDEX historical_finding_comparison_endpoint ON historical_finding(comparison_node_id, comparison_metric);
    CREATE INDEX historical_finding_movement_ancestor ON historical_finding(movement_ancestor_finding_id) WHERE movement_ancestor_finding_id IS NOT NULL;

    CREATE TRIGGER historical_node_validate_insert BEFORE INSERT ON historical_observation_node BEGIN
        SELECT CASE WHEN EXISTS(
            SELECT 1 FROM historical_observation_frame f
            JOIN historical_observation_frame_commit c ON c.frame_id=f.frame_id
            WHERE f.batch_id=NEW.batch_id
        ) THEN RAISE(ABORT, 'historical batch already committed') END;
        SELECT CASE WHEN NOT EXISTS(
            SELECT 1 FROM historical_observation_batch b
            JOIN historical_subject s ON s.subject_key = NEW.subject_key AND s.scope_key = b.scope_key
            JOIN historical_location l ON l.location_key = NEW.location_key AND l.scope_key = b.scope_key
            WHERE b.batch_id = NEW.batch_id AND l.path_semantics_version = b.path_semantics_version
        ) THEN RAISE(ABORT, 'historical node context mismatch') END;
        SELECT CASE WHEN NEW.parent_node_id IS NOT NULL AND NOT EXISTS(
            SELECT 1 FROM historical_observation_node p
            WHERE p.node_id = NEW.parent_node_id AND p.batch_id = NEW.batch_id
        ) THEN RAISE(ABORT, 'historical parent mismatch') END;
    END;

    CREATE TRIGGER historical_metric_endpoint_validate_insert BEFORE INSERT ON historical_metric_endpoint BEGIN
        SELECT CASE WHEN EXISTS(
            SELECT 1 FROM historical_observation_frame_commit c WHERE c.frame_id=NEW.frame_id
        ) THEN RAISE(ABORT, 'historical frame already committed') END;
        SELECT CASE WHEN NOT EXISTS(
            SELECT 1 FROM historical_observation_node n
            JOIN historical_observation_frame f ON f.frame_id = NEW.frame_id
            WHERE n.node_id = NEW.node_id AND n.batch_id = f.batch_id AND f.metric = NEW.metric
        ) THEN RAISE(ABORT, 'endpoint frame mismatch') END;
        SELECT CASE WHEN EXISTS(
            SELECT 1 FROM historical_metric_endpoint peer
            WHERE peer.node_id = NEW.node_id AND peer.metric != NEW.metric
              AND (peer.state_kind != NEW.state_kind
                OR peer.measurement_coverage IS NOT NEW.measurement_coverage
                OR peer.unknown_reason_code IS NOT NEW.unknown_reason_code)
        ) THEN RAISE(ABORT, 'metric sibling shape mismatch') END;
    END;

    CREATE TRIGGER historical_stable_identity_validate_insert BEFORE INSERT ON historical_endpoint_stable_identity BEGIN
        SELECT CASE WHEN EXISTS(
            SELECT 1 FROM historical_observation_node n
            JOIN historical_observation_frame f ON f.batch_id=n.batch_id
            JOIN historical_observation_frame_commit c ON c.frame_id=f.frame_id
            WHERE n.node_id=NEW.node_id
        ) THEN RAISE(ABORT, 'historical stable identity already committed') END;
        SELECT CASE WHEN NOT EXISTS(
            SELECT 1 FROM historical_observation_node n
            JOIN historical_subject s ON s.subject_key = n.subject_key
            WHERE n.node_id = NEW.node_id AND s.identity_basis = 1
        ) THEN RAISE(ABORT, 'stable identity basis mismatch') END;
    END;

    CREATE TRIGGER historical_frame_commit_validate BEFORE INSERT ON historical_observation_frame_commit BEGIN
        SELECT CASE WHEN NOT EXISTS(
            SELECT 1 FROM historical_observation_frame f
            WHERE f.frame_id = NEW.frame_id AND f.metric = NEW.root_metric
        ) THEN RAISE(ABORT, 'frame commit metric mismatch') END;
        SELECT CASE WHEN (SELECT count(*) FROM historical_observation_node n
            JOIN historical_observation_frame f ON f.batch_id = n.batch_id
            WHERE f.frame_id = NEW.frame_id) != NEW.endpoint_count
            THEN RAISE(ABORT, 'endpoint count mismatch') END;
        SELECT CASE WHEN EXISTS(
            SELECT 1 FROM historical_observation_node n
            JOIN historical_observation_frame f ON f.batch_id = n.batch_id
            WHERE f.frame_id = NEW.frame_id
              AND (NOT EXISTS(SELECT 1 FROM historical_metric_endpoint e WHERE e.node_id=n.node_id AND e.metric=1)
                OR NOT EXISTS(SELECT 1 FROM historical_metric_endpoint e WHERE e.node_id=n.node_id AND e.metric=2))
        ) THEN RAISE(ABORT, 'incomplete metric pair') END;
        SELECT CASE WHEN EXISTS(
            SELECT 1 FROM historical_metric_endpoint e
            JOIN historical_observation_frame ef ON ef.frame_id=e.frame_id
            JOIN historical_observation_frame f ON f.frame_id=NEW.frame_id
            LEFT JOIN historical_observation_node n ON n.node_id=e.node_id AND n.batch_id=f.batch_id
            WHERE ef.batch_id=f.batch_id AND n.node_id IS NULL
        ) THEN RAISE(ABORT, 'endpoint node set mismatch') END;
        SELECT CASE WHEN (SELECT count(*) FROM historical_observation_node n
            JOIN historical_observation_frame f ON f.batch_id=n.batch_id
            WHERE f.frame_id=NEW.frame_id AND n.parent_node_id IS NULL) != 1
            THEN RAISE(ABORT, 'historical frame root count mismatch') END;
        SELECT CASE WHEN NOT EXISTS(
            SELECT 1 FROM historical_observation_node n
            JOIN historical_observation_frame f ON f.batch_id=n.batch_id
            JOIN historical_observation_batch b ON b.batch_id=f.batch_id
            JOIN historical_metric_endpoint e ON e.node_id=n.node_id AND e.metric=NEW.root_metric AND e.frame_id=NEW.frame_id
            WHERE f.frame_id=NEW.frame_id AND n.node_id=NEW.root_node_id
              AND n.parent_node_id IS NULL AND n.subject_key=b.root_subject_key AND e.state_kind=1
        ) THEN RAISE(ABORT, 'historical frame root mismatch') END;
        SELECT CASE WHEN NEW.retention_anchor_ms != (
            SELECT min(n.observed_at_ms) FROM historical_observation_node n
            JOIN historical_observation_frame f ON f.batch_id=n.batch_id
            WHERE f.frame_id=NEW.frame_id
        ) THEN RAISE(ABORT, 'retention anchor mismatch') END;
        SELECT CASE WHEN EXISTS(
            SELECT 1 FROM historical_observation_node n
            JOIN historical_observation_frame f ON f.batch_id=n.batch_id
            JOIN historical_subject s ON s.subject_key=n.subject_key
            LEFT JOIN historical_endpoint_stable_identity stable ON stable.node_id=n.node_id
            WHERE f.frame_id=NEW.frame_id
              AND ((s.identity_basis=1 AND stable.node_id IS NULL)
                OR (s.identity_basis=2 AND stable.node_id IS NOT NULL))
        ) THEN RAISE(ABORT, 'stable identity evidence mismatch') END;
        SELECT CASE WHEN EXISTS(
            SELECT 1 FROM historical_observation_node n
            JOIN historical_observation_frame f ON f.batch_id=n.batch_id
            JOIN historical_subject s ON s.subject_key=n.subject_key
            WHERE f.frame_id=NEW.frame_id
            GROUP BY s.subject_id HAVING count(*) != 1
        ) THEN RAISE(ABORT, 'duplicate raw subject identity') END;
        SELECT CASE WHEN EXISTS(
            SELECT 1 FROM historical_observation_node n
            JOIN historical_observation_frame f ON f.batch_id=n.batch_id
            JOIN historical_location l ON l.location_key=n.location_key
            WHERE f.frame_id=NEW.frame_id
            GROUP BY l.location_id HAVING count(*) != 1
        ) THEN RAISE(ABORT, 'duplicate raw location identity') END;
        SELECT CASE WHEN EXISTS(
            SELECT 1 FROM historical_observation_node n
            JOIN historical_observation_frame f ON f.batch_id=n.batch_id
            JOIN historical_location l ON l.location_key=n.location_key
            WHERE f.frame_id=NEW.frame_id
            GROUP BY l.path_utf8 HAVING count(*) != 1
        ) THEN RAISE(ABORT, 'duplicate raw path') END;
        SELECT CASE WHEN EXISTS(
            SELECT 1 FROM historical_observation_node n
            JOIN historical_observation_frame f ON f.batch_id=n.batch_id
            JOIN frozen_attribution_decision d ON d.decision_id=n.classification_decision_id
            WHERE f.frame_id=NEW.frame_id AND d.decision_kind=3
              AND ((SELECT count(*) FROM frozen_attribution_competitor c WHERE c.decision_id=d.decision_id) < 2
                OR (SELECT min(c.ordinal) FROM frozen_attribution_competitor c WHERE c.decision_id=d.decision_id) != 0
                OR (SELECT max(c.ordinal) FROM frozen_attribution_competitor c WHERE c.decision_id=d.decision_id)
                    != (SELECT count(*) - 1 FROM frozen_attribution_competitor c WHERE c.decision_id=d.decision_id)
                OR EXISTS(
                    SELECT 1 FROM frozen_attribution_competitor first
                    JOIN frozen_attribution_competitor second
                      ON second.decision_id=first.decision_id AND second.ordinal=first.ordinal+1
                    WHERE first.decision_id=d.decision_id AND first.rule_id >= second.rule_id))
        ) THEN RAISE(ABORT, 'noncanonical ambiguous attribution') END;
        SELECT CASE WHEN EXISTS(
            SELECT 1 FROM historical_metric_endpoint e
            JOIN historical_observation_node n ON n.node_id=e.node_id
            JOIN historical_observation_frame f ON f.frame_id=NEW.frame_id AND f.batch_id=n.batch_id
            WHERE (e.state_kind=1 AND n.classification_decision_id IS NULL)
               OR (e.state_kind IN (2,3) AND (n.classification_decision_id IS NOT NULL OR n.direct_children_coverage != 3))
               OR (e.state_kind=2 AND (n.parent_node_id IS NULL OR NOT EXISTS(
                    SELECT 1 FROM historical_observation_node p
                    JOIN historical_metric_endpoint pe ON pe.node_id=p.node_id AND pe.metric=e.metric
                    WHERE p.node_id=n.parent_node_id AND p.direct_children_coverage=1
                      AND pe.state_kind=1 AND pe.measurement_coverage=1)))
        ) THEN RAISE(ABORT, 'historical endpoint evidence mismatch') END;
    END;

    CREATE TRIGGER historical_calibration_receipt_validate BEFORE INSERT ON historical_calibration_receipt BEGIN
        SELECT CASE WHEN length(NEW.scan_run_id) != 36 OR lower(NEW.scan_run_id) != NEW.scan_run_id
            OR substr(NEW.scan_run_id,9,1)!='-' OR substr(NEW.scan_run_id,14,1)!='-'
            OR substr(NEW.scan_run_id,19,1)!='-' OR substr(NEW.scan_run_id,24,1)!='-'
            OR replace(NEW.scan_run_id,'-','') GLOB '*[^0-9a-f]*'
            THEN RAISE(ABORT, 'noncanonical calibration run id') END;
        SELECT CASE WHEN EXISTS(
            SELECT 1 FROM historical_disabled_calibration_receipt d
            WHERE lower(hex(d.receipt_id)) = replace(NEW.scan_run_id,'-','')
        ) THEN RAISE(ABORT, 'calibration receipt identity reused') END;
        SELECT CASE WHEN NEW.outcome=1 AND NOT EXISTS(
            SELECT 1 FROM historical_observation_frame_commit l
            JOIN historical_observation_frame_commit a ON a.sequence=NEW.allocated_sequence
            JOIN historical_observation_frame lf ON lf.frame_id=l.frame_id AND lf.metric=1
            JOIN historical_observation_frame af ON af.frame_id=a.frame_id AND af.metric=2
            JOIN historical_observation_batch b ON b.batch_id=lf.batch_id AND b.batch_id=af.batch_id
            WHERE l.sequence=NEW.logical_sequence AND b.scan_run_id=NEW.scan_run_id
              AND NEW.retention_anchor_ms=l.retention_anchor_ms AND NEW.retention_anchor_ms=a.retention_anchor_ms
        ) THEN RAISE(ABORT, 'published receipt frame mismatch') END;
    END;

    CREATE TRIGGER historical_disabled_calibration_receipt_validate BEFORE INSERT ON historical_disabled_calibration_receipt BEGIN
        SELECT CASE WHEN EXISTS(
            SELECT 1 FROM historical_calibration_receipt r
            WHERE replace(r.scan_run_id,'-','') = lower(hex(NEW.receipt_id))
        ) THEN RAISE(ABORT, 'disabled receipt identity reused') END;
    END;

    CREATE TRIGGER historical_baseline_validate_series BEFORE INSERT ON historical_observation_baseline_checkpoint BEGIN
        SELECT CASE WHEN EXISTS(SELECT 1 FROM historical_projection_work WHERE comparison_sequence=NEW.frame_sequence)
            THEN RAISE(ABORT, 'frame already projection work') END;
    END;

    CREATE TRIGGER historical_work_validate_pair BEFORE INSERT ON historical_projection_work BEGIN
        SELECT CASE WHEN EXISTS(SELECT 1 FROM historical_observation_baseline_checkpoint WHERE frame_sequence=NEW.comparison_sequence)
            THEN RAISE(ABORT, 'frame already baseline checkpoint') END;
        SELECT CASE WHEN NOT EXISTS(
            SELECT 1 FROM historical_observation_frame_commit b
            JOIN historical_observation_frame_commit c ON c.sequence=NEW.comparison_sequence
            JOIN historical_observation_frame bf ON bf.frame_id=b.frame_id
            JOIN historical_observation_frame cf ON cf.frame_id=c.frame_id AND cf.metric=bf.metric
            JOIN historical_observation_batch bb ON bb.batch_id=bf.batch_id
            JOIN historical_observation_batch cb ON cb.batch_id=cf.batch_id AND cb.scope_key=bb.scope_key
            WHERE b.sequence=NEW.baseline_sequence
        ) THEN RAISE(ABORT, 'projection frame pair mismatch') END;
        SELECT CASE WHEN EXISTS(
            SELECT 1 FROM historical_observation_frame_commit middle
            JOIN historical_observation_frame mf ON mf.frame_id=middle.frame_id
            JOIN historical_observation_batch mb ON mb.batch_id=mf.batch_id
            JOIN historical_observation_frame_commit baseline ON baseline.sequence=NEW.baseline_sequence
            JOIN historical_observation_frame bf ON bf.frame_id=baseline.frame_id
            JOIN historical_observation_batch bb ON bb.batch_id=bf.batch_id
            WHERE middle.sequence > NEW.baseline_sequence
              AND middle.sequence < NEW.comparison_sequence
              AND mf.metric=bf.metric AND mb.scope_key=bb.scope_key
        ) THEN RAISE(ABORT, 'projection baseline is not immediate predecessor') END;
    END;

    CREATE TRIGGER historical_finding_validate_insert BEFORE INSERT ON historical_finding BEGIN
        SELECT CASE WHEN NOT EXISTS(
            SELECT 1 FROM historical_finding_projection p
            JOIN historical_projection_work w ON w.work_id=p.work_id
            JOIN historical_observation_frame_commit bc ON bc.sequence=w.baseline_sequence
            JOIN historical_observation_frame_commit cc ON cc.sequence=w.comparison_sequence
            JOIN historical_observation_frame bf ON bf.frame_id=bc.frame_id
            JOIN historical_observation_frame cf ON cf.frame_id=cc.frame_id
            JOIN historical_observation_node bn ON bn.node_id=NEW.baseline_node_id AND bn.batch_id=bf.batch_id
            JOIN historical_observation_node cn ON cn.node_id=NEW.comparison_node_id AND cn.batch_id=cf.batch_id
            WHERE p.projection_id=NEW.projection_id AND bf.metric=NEW.baseline_metric
              AND cf.metric=NEW.comparison_metric
              AND NEW.expires_at_ms=min(bc.expires_at_ms,cc.expires_at_ms)
        ) THEN RAISE(ABORT, 'finding work mismatch') END;
        SELECT CASE WHEN NEW.movement_ancestor_finding_id IS NOT NULL AND NOT EXISTS(
            SELECT 1 FROM historical_finding a
            WHERE a.finding_id=NEW.movement_ancestor_finding_id AND a.projection_id=NEW.projection_id AND a.kind=5
        ) THEN RAISE(ABORT, 'finding movement ancestor mismatch') END;
        SELECT CASE WHEN NOT EXISTS(
            SELECT 1 FROM historical_metric_endpoint baseline
            JOIN historical_metric_endpoint comparison
              ON comparison.node_id=NEW.comparison_node_id
             AND comparison.metric=NEW.comparison_metric
            JOIN historical_observation_node bn ON bn.node_id=baseline.node_id
            JOIN historical_observation_node cn ON cn.node_id=comparison.node_id
            JOIN historical_subject bs ON bs.subject_key=bn.subject_key
            LEFT JOIN historical_endpoint_stable_identity bstable ON bstable.node_id=bn.node_id
            LEFT JOIN historical_endpoint_stable_identity cstable ON cstable.node_id=cn.node_id
            WHERE baseline.node_id=NEW.baseline_node_id AND baseline.metric=NEW.baseline_metric
              AND bn.subject_key=cn.subject_key
              AND (
                (NEW.kind=1 AND baseline.state_kind=2 AND comparison.state_kind=1
                    AND bn.location_key=cn.location_key
                    AND NEW.inclusive_delta_bytes>0 AND NEW.ranking_contribution_bytes IS NOT NULL)
                OR (NEW.kind=2 AND baseline.state_kind=1 AND comparison.state_kind=1
                    AND bn.location_key=cn.location_key AND NEW.inclusive_delta_bytes<0)
                OR (NEW.kind=3 AND baseline.state_kind=1 AND comparison.state_kind=2
                    AND bn.location_key=cn.location_key
                    AND NEW.inclusive_delta_bytes<0 AND NEW.ranking_contribution_bytes IS NULL)
                OR (NEW.kind=4 AND baseline.state_kind=1 AND comparison.state_kind=1
                    AND bn.location_key=cn.location_key AND NEW.inclusive_delta_bytes>0)
                OR (NEW.kind=5 AND baseline.state_kind=1 AND comparison.state_kind=1
                    AND bn.location_key!=cn.location_key AND NEW.ranking_contribution_bytes IS NULL
                    AND bs.identity_basis=1 AND bstable.node_id IS NOT NULL
                    AND cstable.node_id IS NOT NULL AND bstable.guard_kind=cstable.guard_kind
                    AND bstable.generation_token_utf8 IS cstable.generation_token_utf8
                    AND bstable.birth_seconds IS cstable.birth_seconds
                    AND bstable.birth_nanoseconds IS cstable.birth_nanoseconds
                    AND bstable.node_kind=cstable.node_kind
                    AND bstable.link_status=1 AND cstable.link_status=1)
              )
        ) THEN RAISE(ABORT, 'finding v1 shape mismatch') END;
    END;

    CREATE TRIGGER historical_rank_validate_projection BEFORE INSERT ON historical_finding_positive_rank BEGIN
        SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM historical_finding f WHERE f.finding_id=NEW.finding_id AND f.projection_id=NEW.projection_id)
            THEN RAISE(ABORT, 'finding rank projection mismatch') END;
    END;

    CREATE TRIGGER historical_retraction_validate_target BEFORE INSERT ON historical_finding_retraction BEGIN
        SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM historical_finding f WHERE f.finding_id=NEW.retracted_finding_id AND f.draft_sha256=NEW.expected_draft_sha256)
            THEN RAISE(ABORT, 'retraction target mismatch') END;
    END;

    """# + immutableTriggerSQL

    private static let immutableTriggerSQL: String = {
        let mappings = [
            ("historical_store_identity_immutable_update", "historical_store_identity"),
            ("historical_scope_immutable_update", "historical_scope"),
            ("historical_subject_immutable_update", "historical_subject"),
            ("historical_location_immutable_update", "historical_location"),
            ("historical_attribution_decision_immutable_update", "frozen_attribution_decision"),
            ("historical_attribution_competitor_immutable_update", "frozen_attribution_competitor"),
            ("historical_batch_immutable_update", "historical_observation_batch"),
            ("historical_frame_immutable_update", "historical_observation_frame"),
            ("historical_node_immutable_update", "historical_observation_node"),
            ("historical_metric_endpoint_immutable_update", "historical_metric_endpoint"),
            ("historical_stable_identity_immutable_update", "historical_endpoint_stable_identity"),
            ("historical_frame_commit_immutable_update", "historical_observation_frame_commit"),
            ("historical_calibration_receipt_immutable_update", "historical_calibration_receipt"),
            ("historical_disabled_calibration_receipt_immutable_update", "historical_disabled_calibration_receipt"),
            ("historical_baseline_checkpoint_immutable_update", "historical_observation_baseline_checkpoint"),
            ("historical_projection_work_immutable_update", "historical_projection_work"),
            ("historical_projection_immutable_update", "historical_finding_projection"),
            ("historical_projection_checkpoint_immutable_update", "historical_projection_checkpoint"),
            ("historical_finding_immutable_update", "historical_finding"),
            ("historical_rank_immutable_update", "historical_finding_positive_rank"),
            ("historical_reason_count_immutable_update", "historical_finding_reason_count"),
            ("historical_retraction_immutable_update", "historical_finding_retraction"),
        ]
        return mappings.map { trigger, table in
            "CREATE TRIGGER \(trigger) BEFORE UPDATE ON \(table) BEGIN SELECT RAISE(ABORT, 'immutable historical evidence'); END;"
        }.joined(separator: "\n")
    }()

    private struct PrototypeSeedCounts {
        let scopeCount: Int
        let subjectCount: Int
        let insertedNodeCount: Int
        let expiredBatchIDs: [Int64]
    }

    private static func seedPrototype(
        _ database: OpaquePointer,
        directorySamples: Int,
        scenario: SQLiteHistoricalPrototypeScenario
    ) throws -> PrototypeSeedCounts {
        let retainedV11Target = scenario == .legacyOverlap
            ? directorySamples / 2
            : directorySamples
        guard retainedV11Target.isMultiple(of: 25) else {
            throw SQLiteHistoricalFindingSchemaError.invalidDirectorySampleCount
        }
        let nodesPerDay = retainedV11Target / 25
        let scopeCount = scenario == .highFrameCount ? 100 : 1
        guard nodesPerDay >= scopeCount, nodesPerDay.isMultiple(of: scopeCount) else {
            throw SQLiteHistoricalFindingSchemaError.invalidDirectorySampleCount
        }
        let nodesPerScope = nodesPerDay / scopeCount
        let allStable = scenario == .allStableIdentity
        let churn = scenario == .twoPercentChurn
        let referenceMilliseconds: Int64 = 2_212_336_800_000
        let dayMilliseconds: Int64 = 86_400_000

        try execute(database, "BEGIN IMMEDIATE")
        do {
            try execute(
                database,
                "INSERT OR IGNORE INTO historical_store_identity VALUES(1,1,X'00112233445566778899aabbccddeeff')"
            )
            try insertPrototypeDecisions(database)
            try insertPrototypeDictionaries(
                database,
                scopeCount: scopeCount,
                nodesPerScope: nodesPerScope,
                allStable: allStable
            )
            if scenario == .legacyOverlap {
                try insertPrototypeLegacyRows(
                    database,
                    count: directorySamples - retainedV11Target,
                    referenceMilliseconds: referenceMilliseconds
                )
            }
            try execute(database, "COMMIT")
        } catch {
            try? execute(database, "ROLLBACK")
            throw error
        }

        let insertRun = try PrototypeStatement(
            database,
            "INSERT INTO scan_run(id,stream_id,region_path,dirty_revision_be,state,coverage,entries_seen,directories_staged,started_at_ms,finished_at_ms) VALUES(?,?,?,zeroblob(8),'completed','complete',?,?,?,?)"
        )
        let insertBatch = try PrototypeStatement(
            database,
            "INSERT INTO historical_observation_batch(scan_run_id,stream_id_utf8,scope_key,root_subject_key,volume_id,mount_generation_id,coverage_epoch_id,path_semantics_version,measurement_semantics_version,created_at_ms) VALUES(?,?,?,?,?,?,?,1,1,?)"
        )
        let insertFrame = try PrototypeStatement(
            database,
            "INSERT INTO historical_observation_frame(frame_id,batch_id,metric) VALUES(?,?,?)"
        )
        let insertNode = try PrototypeStatement(
            database,
            "INSERT INTO historical_observation_node(batch_id,subject_key,location_key,parent_node_id,observed_at_ms,direct_children_coverage,classification_decision_id) VALUES(?,?,?,?,?,?,?)"
        )
        let insertEndpoint = try PrototypeStatement(
            database,
            "INSERT INTO historical_metric_endpoint(node_id,metric,frame_id,state_kind,bytes,measurement_coverage,unknown_reason_code) VALUES(?,?,?,?,?,?,?)"
        )
        let insertStableToken = try PrototypeStatement(
            database,
            "INSERT INTO historical_endpoint_stable_identity(node_id,guard_kind,generation_token_utf8,birth_seconds,birth_nanoseconds,node_kind,link_status) VALUES(?,1,?,NULL,NULL,1,1)"
        )
        let insertStableBirth = try PrototypeStatement(
            database,
            "INSERT INTO historical_endpoint_stable_identity(node_id,guard_kind,generation_token_utf8,birth_seconds,birth_nanoseconds,node_kind,link_status) VALUES(?,2,NULL,?,?,1,1)"
        )
        let insertCommit = try PrototypeStatement(
            database,
            "INSERT INTO historical_observation_frame_commit(frame_id,root_node_id,root_metric,endpoint_count,committed_at_ms,retention_anchor_ms,expires_at_ms) VALUES(?,?,?,?,?,?,?)"
        )
        let insertReceipt = try PrototypeStatement(
            database,
            "INSERT INTO historical_calibration_receipt(scan_run_id,request_format_version,canonical_request_sha256,outcome,logical_sequence,allocated_sequence,committed_at_ms,retention_anchor_ms,expires_at_ms) VALUES(?,1,?,1,?,?,?,?,?)"
        )
        let insertBaseline = try PrototypeStatement(
            database,
            "INSERT INTO historical_observation_baseline_checkpoint(frame_sequence,checkpoint_kind,committed_at_ms) VALUES(?,1,?)"
        )
        let insertWork = try PrototypeStatement(
            database,
            "INSERT INTO historical_projection_work(baseline_sequence,comparison_sequence,algorithm_version,ranking_policy_version,positive_limit,created_at_ms) VALUES(?,?,1,1,10,?)"
        )
        let insertProjection = try PrototypeStatement(
            database,
            "INSERT INTO historical_finding_projection(work_id,format_version,canonical_result_sha256,truncated_positive_count,committed_at_ms) VALUES(?,1,?,0,?)"
        )
        let insertProjectionCheckpoint = try PrototypeStatement(
            database,
            "INSERT INTO historical_projection_checkpoint(work_id,committed_at_ms) VALUES(?,?)"
        )
        let insertFinding = try PrototypeStatement(
            database,
            "INSERT INTO historical_finding(projection_id,ordinal,finding_key_sha256,draft_sha256,baseline_node_id,baseline_metric,comparison_node_id,comparison_metric,kind,inclusive_delta_bytes,ranking_contribution_bytes,movement_ancestor_finding_id,expires_at_ms) VALUES(?,?,?,?,?,?,?,?,5,0,NULL,NULL,?)"
        )
        let insertLocation = try PrototypeStatement(
            database,
            "INSERT INTO historical_location(location_key,scope_key,path_semantics_version,location_id,path_utf8,display_name_utf8) VALUES(?,?,1,?,?,?)"
        )

        var previousNodeIDs = Array(repeating: Int64(0), count: nodesPerDay + 1)
        var previousSequences = Array(
            repeating: (logical: Int64(0), allocated: Int64(0)),
            count: scopeCount
        )
        var nextLocationKey = Int64(nodesPerDay + 1)
        var expiredBatchIDs: [Int64] = []
        var insertedNodeCount = 0
        var findingOrdinalByProjection: [Int64: Int] = [:]

        for observationDay in 0..<30 {
            let retainedDay = observationDay >= 5
            let observedAt = referenceMilliseconds - Int64(29 - observationDay) * dayMilliseconds
            for scopeOffset in 0..<scopeCount {
                try execute(database, "BEGIN IMMEDIATE")
                do {
                    let runID = prototypeRunID(day: observationDay, scope: scopeOffset)
                    let streamID = fixedASCII(prefix: "stream-", count: 32, value: scopeOffset)
                    try insertRun.run([
                        .text(runID),
                        .text(streamID),
                        .text("/Fixtures/V11"),
                        .integer(Int64(nodesPerScope)),
                        .integer(Int64(nodesPerScope)),
                        .integer(observedAt),
                        .integer(observedAt + 2_000),
                    ])
                    let firstSubjectKey = scopeOffset * nodesPerScope + 1
                    try insertBatch.run([
                        .text(runID),
                        .blob(Data(streamID.utf8)),
                        .integer(Int64(scopeOffset + 1)),
                        .integer(Int64(firstSubjectKey)),
                        .blob(Data(fixedASCII(prefix: "volume-", count: 36, value: scopeOffset).utf8)),
                        .blob(Data(fixedASCII(prefix: "mount-", count: 32, value: scopeOffset).utf8)),
                        .blob(Data(fixedASCII(prefix: "epoch-", count: 32, value: observationDay).utf8)),
                        .integer(observedAt),
                    ])
                    let batchID = sqlite3_last_insert_rowid(database)
                    if retainedDay == false { expiredBatchIDs.append(batchID) }
                    let logicalFrameID = batchID * 2 - 1
                    let allocatedFrameID = batchID * 2
                    try insertFrame.run([.integer(logicalFrameID), .integer(batchID), .integer(1)])
                    try insertFrame.run([.integer(allocatedFrameID), .integer(batchID), .integer(2)])

                    var rootNodeID: Int64 = 0
                    var currentNodeIDs = Array(repeating: Int64(0), count: nodesPerScope)
                    var movedGlobalSubjects: [Int] = []
                    for localOffset in 0..<nodesPerScope {
                        let globalIndex = scopeOffset * nodesPerScope + localOffset
                        let subjectKey = globalIndex + 1
                        let isRoot = localOffset == 0
                        let stateKind: Int64
                        if isRoot { stateKind = 1 }
                        else if globalIndex % 50 == 48 { stateKind = 2 }
                        else if globalIndex % 50 == 49 { stateKind = 3 }
                        else { stateKind = 1 }
                        let changedLocation = churn && retainedDay && observationDay > 5
                            && globalIndex % 50 == 5
                        let locationKey: Int64
                        if changedLocation {
                            locationKey = nextLocationKey
                            nextLocationKey += 1
                            try insertLocation.run([
                                .integer(locationKey),
                                .integer(Int64(scopeOffset + 1)),
                                .blob(Data(fixedASCII(prefix: "l", count: 21, value: Int(locationKey)).utf8)),
                                .blob(Data(fixedPath(value: Int(locationKey)).utf8)),
                                .blob(Data(fixedASCII(prefix: "d", count: 16, value: Int(locationKey)).utf8)),
                            ])
                            movedGlobalSubjects.append(globalIndex)
                        } else {
                            locationKey = Int64(subjectKey)
                        }
                        let classificationID: SQLitePrototypeBinding = stateKind == 1
                            ? .integer(globalIndex % 20 == 0 ? Int64(2 + globalIndex % 64) : 1)
                            : .null
                        try insertNode.run([
                            .integer(batchID),
                            .integer(Int64(subjectKey)),
                            .integer(locationKey),
                            isRoot ? .null : .integer(rootNodeID),
                            .integer(observedAt),
                            .integer(stateKind == 1 ? 1 : 3),
                            classificationID,
                        ])
                        let nodeID = sqlite3_last_insert_rowid(database)
                        if isRoot { rootNodeID = nodeID }
                        currentNodeIDs[localOffset] = nodeID
                        let logicalBytes = Int64(globalIndex + 1) * 1_000
                        let allocatedBytes = logicalBytes + 512
                        for (metric, frameID, bytes) in [
                            (Int64(1), logicalFrameID, logicalBytes),
                            (Int64(2), allocatedFrameID, allocatedBytes),
                        ] {
                            switch stateKind {
                            case 1:
                                try insertEndpoint.run([
                                    .integer(nodeID), .integer(metric), .integer(frameID),
                                    .integer(1), .integer(bytes), .integer(1), .null,
                                ])
                            case 2:
                                try insertEndpoint.run([
                                    .integer(nodeID), .integer(metric), .integer(frameID),
                                    .integer(2), .null, .null, .null,
                                ])
                            default:
                                try insertEndpoint.run([
                                    .integer(nodeID), .integer(metric), .integer(frameID),
                                    .integer(3), .null, .null, .integer(4),
                                ])
                            }
                        }
                        let stable = allStable || globalIndex % 5 == 0
                        if stable {
                            if globalIndex.isMultiple(of: 2) {
                                try insertStableToken.run([
                                    .integer(nodeID),
                                    .blob(Data(fixedASCII(prefix: "generation-", count: 32, value: globalIndex).utf8)),
                                ])
                            } else {
                                try insertStableBirth.run([
                                    .integer(nodeID),
                                    .integer(1_700_000_000 + Int64(globalIndex)),
                                    .integer(Int64(globalIndex % 1_000_000_000)),
                                ])
                            }
                        }
                    }
                    insertedNodeCount += nodesPerScope
                    let expiry = observedAt + 2_592_000_000
                    try insertCommit.run([
                        .integer(logicalFrameID), .integer(rootNodeID), .integer(1),
                        .integer(Int64(nodesPerScope)), .integer(observedAt + 2_000),
                        .integer(observedAt), .integer(expiry),
                    ])
                    let logicalSequence = sqlite3_last_insert_rowid(database)
                    try insertCommit.run([
                        .integer(allocatedFrameID), .integer(rootNodeID), .integer(2),
                        .integer(Int64(nodesPerScope)), .integer(observedAt + 2_000),
                        .integer(observedAt), .integer(expiry),
                    ])
                    let allocatedSequence = sqlite3_last_insert_rowid(database)
                    try insertReceipt.run([
                        .text(runID), .blob(prototypeDigest(batchID)),
                        .integer(logicalSequence), .integer(allocatedSequence),
                        .integer(observedAt + 2_000), .integer(observedAt), .integer(expiry),
                    ])

                    if observationDay == 5 {
                        try insertBaseline.run([.integer(logicalSequence), .integer(observedAt + 2_000)])
                        try insertBaseline.run([.integer(allocatedSequence), .integer(observedAt + 2_000)])
                    } else if observationDay > 5 {
                        for (metric, baselineSequence, comparisonSequence) in [
                            (1, previousSequences[scopeOffset].logical, logicalSequence),
                            (2, previousSequences[scopeOffset].allocated, allocatedSequence),
                        ] {
                            try insertWork.run([
                                .integer(baselineSequence), .integer(comparisonSequence),
                                .integer(observedAt + 2_000),
                            ])
                            let workID = sqlite3_last_insert_rowid(database)
                            try insertProjection.run([
                                .integer(workID), .blob(prototypeDigest(workID + 10_000_000)),
                                .integer(observedAt + 2_000),
                            ])
                            let projectionID = sqlite3_last_insert_rowid(database)
                            if churn {
                                var ordinal = findingOrdinalByProjection[projectionID, default: 0]
                                for globalIndex in movedGlobalSubjects {
                                    let localIndex = globalIndex - scopeOffset * nodesPerScope
                                    let baselineNodeID = previousNodeIDs[globalIndex + 1]
                                    let comparisonNodeID = currentNodeIDs[localIndex]
                                    try insertFinding.run([
                                        .integer(projectionID), .integer(Int64(ordinal)),
                                        .blob(prototypeDigest(projectionID &* 1_000_000 + Int64(ordinal))),
                                        .blob(prototypeDigest(projectionID &* 2_000_000 + Int64(ordinal))),
                                        .integer(baselineNodeID), .integer(Int64(metric)),
                                        .integer(comparisonNodeID), .integer(Int64(metric)),
                                        .integer(observedAt - dayMilliseconds + 2_592_000_000),
                                    ])
                                    ordinal += 1
                                }
                                findingOrdinalByProjection[projectionID] = ordinal
                            }
                            try insertProjectionCheckpoint.run([
                                .integer(workID), .integer(observedAt + 2_000),
                            ])
                        }
                    }
                    if retainedDay {
                        for localOffset in 0..<nodesPerScope {
                            let globalIndex = scopeOffset * nodesPerScope + localOffset
                            previousNodeIDs[globalIndex + 1] = currentNodeIDs[localOffset]
                        }
                        previousSequences[scopeOffset] = (logicalSequence, allocatedSequence)
                    }
                    try execute(database, "COMMIT")
                } catch {
                    try? execute(database, "ROLLBACK")
                    throw error
                }
            }
        }
        return PrototypeSeedCounts(
            scopeCount: scopeCount,
            subjectCount: nodesPerDay,
            insertedNodeCount: insertedNodeCount,
            expiredBatchIDs: expiredBatchIDs
        )
    }

    private static func insertPrototypeDecisions(_ database: OpaquePointer) throws {
        let decision = try PrototypeStatement(
            database,
            "INSERT INTO frozen_attribution_decision(decision_id,format_version,canonical_payload,canonical_sha256,catalog_version,decision_kind,category_code,confidence_code,rule_id,rule_version,evidence_code) VALUES(?,1,?,?,1,?,?,?,?,?,?)"
        )
        try decision.run([
            .integer(1), .blob(Data(repeating: 0x4e, count: 128)),
            .blob(prototypeDigest(1)), .integer(2), .null, .null, .null, .null, .null,
        ])
        let competitor = try PrototypeStatement(
            database,
            "INSERT INTO frozen_attribution_competitor(decision_id,ordinal,rule_id) VALUES(?,?,?)"
        )
        for offset in 0..<64 {
            let decisionID = Int64(offset + 2)
            let ambiguous = offset >= 32
            try decision.run([
                .integer(decisionID), .blob(Data(repeating: UInt8(offset), count: 128)),
                .blob(prototypeDigest(decisionID)), .integer(ambiguous ? 3 : 1),
                ambiguous ? .null : .integer(Int64(1 + offset % 8)),
                ambiguous ? .null : .integer(Int64(1 + offset % 3)),
                ambiguous ? .null : .blob(Data(fixedASCII(prefix: "r", count: 16, value: offset).utf8)),
                ambiguous ? .null : .integer(1),
                ambiguous ? .null : .blob(Data(fixedASCII(prefix: "e", count: 16, value: offset).utf8)),
            ])
            if ambiguous {
                try competitor.run([.integer(decisionID), .integer(0), .blob(Data(fixedASCII(prefix: "a", count: 16, value: offset).utf8))])
                try competitor.run([.integer(decisionID), .integer(1), .blob(Data(fixedASCII(prefix: "b", count: 16, value: offset).utf8))])
            }
        }
    }

    private static func insertPrototypeDictionaries(
        _ database: OpaquePointer,
        scopeCount: Int,
        nodesPerScope: Int,
        allStable: Bool
    ) throws {
        let insertScope = try PrototypeStatement(
            database,
            "INSERT INTO historical_scope(scope_key,scope_id) VALUES(?,?)"
        )
        let insertSubject = try PrototypeStatement(
            database,
            "INSERT INTO historical_subject(subject_key,scope_key,identity_basis,subject_id) VALUES(?,?,?,?)"
        )
        let insertLocation = try PrototypeStatement(
            database,
            "INSERT INTO historical_location(location_key,scope_key,path_semantics_version,location_id,path_utf8,display_name_utf8) VALUES(?,?,1,?,?,?)"
        )
        for scopeOffset in 0..<scopeCount {
            let scopeKey = Int64(scopeOffset + 1)
            try insertScope.run([
                .integer(scopeKey),
                .blob(Data(fixedASCII(prefix: "p", count: 16, value: scopeOffset).utf8)),
            ])
            for localOffset in 0..<nodesPerScope {
                let globalIndex = scopeOffset * nodesPerScope + localOffset
                let key = Int64(globalIndex + 1)
                let stable = allStable || globalIndex % 5 == 0
                try insertSubject.run([
                    .integer(key), .integer(scopeKey), .integer(stable ? 1 : 2),
                    .blob(Data(fixedASCII(prefix: "s", count: 20, value: globalIndex).utf8)),
                ])
                try insertLocation.run([
                    .integer(key), .integer(scopeKey),
                    .blob(Data(fixedASCII(prefix: "l", count: 21, value: globalIndex).utf8)),
                    .blob(Data(fixedPath(value: globalIndex).utf8)),
                    .blob(Data(fixedASCII(prefix: "d", count: 16, value: globalIndex).utf8)),
                ])
            }
        }
    }

    private static func insertPrototypeLegacyRows(
        _ database: OpaquePointer,
        count: Int,
        referenceMilliseconds: Int64
    ) throws {
        let statement = try PrototypeStatement(
            database,
            "INSERT INTO directory_history_sample(stream_id,path,bucket_kind,bucket_start_ms,logical_bytes,logical_delta,allocated_bytes,descendant_count,coverage,scan_run_id) VALUES('v11-overlap',?,'daily',?,?,0,?,0,'complete','v11-overlap')"
        )
        for offset in 0..<count {
            let day = offset % 25
            let pathIndex = offset / 25
            try statement.run([
                .text(String(format: "/Fixtures/Legacy/p%08d", pathIndex)),
                .integer(referenceMilliseconds - Int64(24 - day) * 86_400_000),
                .integer(Int64(pathIndex + 1) * 1_000),
                .integer(Int64(pathIndex + 1) * 1_024),
            ])
        }
    }

    private static func retainPrototypeWindow(
        _ database: OpaquePointer,
        expiredBatchIDs: [Int64]
    ) throws {
        guard expiredBatchIDs.isEmpty == false else { return }
        try execute(database, "BEGIN IMMEDIATE")
        do {
            let values = expiredBatchIDs.map(String.init).joined(separator: ",")
            let batchFilter = "(\(values))"
            try execute(database, "DELETE FROM historical_calibration_receipt WHERE scan_run_id IN (SELECT scan_run_id FROM historical_observation_batch WHERE batch_id IN \(batchFilter))")
            try execute(database, "DELETE FROM historical_observation_frame_commit WHERE frame_id IN (SELECT frame_id FROM historical_observation_frame WHERE batch_id IN \(batchFilter))")
            try execute(database, "DELETE FROM historical_endpoint_stable_identity WHERE node_id IN (SELECT node_id FROM historical_observation_node WHERE batch_id IN \(batchFilter))")
            try execute(database, "DELETE FROM historical_metric_endpoint WHERE node_id IN (SELECT node_id FROM historical_observation_node WHERE batch_id IN \(batchFilter))")
            try execute(database, "DELETE FROM historical_observation_node WHERE batch_id IN \(batchFilter) AND parent_node_id IS NOT NULL")
            try execute(database, "DELETE FROM historical_observation_node WHERE batch_id IN \(batchFilter)")
            try execute(database, "DELETE FROM historical_observation_frame WHERE batch_id IN \(batchFilter)")
            try execute(database, "DELETE FROM historical_observation_batch WHERE batch_id IN \(batchFilter)")
            try execute(database, "DELETE FROM scan_run WHERE stream_id LIKE 'stream-%' AND id NOT IN (SELECT scan_run_id FROM historical_observation_batch)")
            try execute(database, "COMMIT")
        } catch {
            try? execute(database, "ROLLBACK")
            throw error
        }
    }

    private static func prototypeObjectSizes(
        _ database: OpaquePointer
    ) throws -> [SQLiteHistoricalPrototypeObjectSize] {
        let statement = try PrototypeStatement(
            database,
            "SELECT name,sum(pgsize) FROM dbstat GROUP BY name ORDER BY sum(pgsize) DESC,name"
        )
        var result: [SQLiteHistoricalPrototypeObjectSize] = []
        while try statement.step() {
            result.append(
                SQLiteHistoricalPrototypeObjectSize(
                    name: statement.text(at: 0),
                    bytes: statement.integer(at: 1)
                )
            )
        }
        return result
    }

    private static func prototypeQueryPlans(_ database: OpaquePointer) throws -> [String] {
        let queries = [
            "EXPLAIN QUERY PLAN SELECT node_id,state_kind,bytes FROM historical_metric_endpoint WHERE frame_id=1 ORDER BY node_id",
            "EXPLAIN QUERY PLAN SELECT finding_id FROM historical_finding WHERE baseline_node_id=1 AND baseline_metric=1",
            "EXPLAIN QUERY PLAN SELECT batch_id FROM historical_observation_batch WHERE scope_key=1 ORDER BY batch_id DESC",
        ]
        return try queries.flatMap { sql -> [String] in
            let statement = try PrototypeStatement(database, sql)
            var rows: [String] = []
            while try statement.step() { rows.append(statement.text(at: 3)) }
            return rows
        }
    }

    private static func querySingleText(_ database: OpaquePointer, _ sql: String) throws -> String {
        let statement = try PrototypeStatement(database, sql)
        guard try statement.step() else { throw SQLiteHistoricalFindingSchemaError.sqlite("missing text result") }
        return statement.text(at: 0)
    }

    private static func querySingleInt(_ database: OpaquePointer, _ sql: String) throws -> Int {
        let statement = try PrototypeStatement(database, sql)
        guard try statement.step() else { throw SQLiteHistoricalFindingSchemaError.sqlite("missing integer result") }
        return Int(statement.integer(at: 0))
    }

    private static func queryRowCount(_ database: OpaquePointer, _ sql: String) throws -> Int {
        let statement = try PrototypeStatement(database, sql)
        var count = 0
        while try statement.step() { count += 1 }
        return count
    }

    private static func databaseBytes(_ url: URL) throws -> Int64 {
        let values = try databaseComponentBytes(url)
        return values.main + values.wal + values.shm
    }

    private static func databaseComponentBytes(
        _ url: URL
    ) throws -> (main: Int64, wal: Int64, shm: Int64) {
        let values = try ["", "-wal", "-shm"].map { suffix -> Int64 in
            let path = url.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { return 0 }
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        return (values[0], values[1], values[2])
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private static func prototypeRunID(day: Int, scope: Int) -> String {
        let value = UInt64(day) * 10_000 + UInt64(scope)
        return String(format: "%08x-0000-4000-8000-%012llx", day, value)
    }

    private static func fixedASCII(prefix: String, count: Int, value: Int) -> String {
        let remaining = max(1, count - prefix.utf8.count)
        let rawDigits = String(value)
        let digits = String(rawDigits.suffix(remaining))
        let fill = max(0, remaining - digits.utf8.count)
        return prefix + String(repeating: "0", count: fill) + digits
    }

    private static func fixedPath(value: Int) -> String {
        fixedASCII(prefix: "/Fixtures/", count: 64, value: value)
    }

    private static func prototypeDigest(_ value: Int64) -> Data {
        var first = UInt64(bitPattern: value).bigEndian
        var second = UInt64(bitPattern: value &* 31 &+ 7).bigEndian
        var third = UInt64(bitPattern: value &* 131 &+ 17).bigEndian
        var fourth = UInt64(bitPattern: value &* 521 &+ 29).bigEndian
        var result = Data()
        withUnsafeBytes(of: &first) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: &second) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: &third) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: &fourth) { result.append(contentsOf: $0) }
        return result
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw SQLiteHistoricalFindingSchemaError.sqlite(message)
        }
    }
}

enum SQLiteHistoricalFindingSchemaError: Error, Sendable, Equatable {
    case sqlite(String)
    case invalidDirectorySampleCount
}

private enum SQLitePrototypeBinding {
    case integer(Int64)
    case blob(Data)
    case text(String)
    case null
}

private final class PrototypeStatement {
    private let database: OpaquePointer
    private let statement: OpaquePointer

    init(_ database: OpaquePointer, _ sql: String) throws {
        self.database = database
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK,
              let prepared else {
            throw SQLiteHistoricalFindingSchemaError.sqlite(
                String(cString: sqlite3_errmsg(database))
            )
        }
        statement = prepared
    }

    deinit {
        sqlite3_finalize(statement)
    }

    func run(_ bindings: [SQLitePrototypeBinding] = []) throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        try bind(bindings)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteHistoricalFindingSchemaError.sqlite(
                String(cString: sqlite3_errmsg(database))
            )
        }
    }

    func step() throws -> Bool {
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw SQLiteHistoricalFindingSchemaError.sqlite(
            String(cString: sqlite3_errmsg(database))
        )
    }

    func integer(at column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    func text(at column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func bind(_ bindings: [SQLitePrototypeBinding]) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case let .integer(value):
                result = sqlite3_bind_int64(statement, index, value)
            case let .blob(value):
                result = value.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(
                        statement,
                        index,
                        buffer.baseAddress,
                        Int32(value.count),
                        sqlitePrototypeTransient
                    )
                }
            case let .text(value):
                result = value.withCString {
                    sqlite3_bind_text(statement, index, $0, -1, sqlitePrototypeTransient)
                }
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else {
                throw SQLiteHistoricalFindingSchemaError.sqlite(
                    String(cString: sqlite3_errmsg(database))
                )
            }
        }
    }
}

private let sqlitePrototypeTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)
