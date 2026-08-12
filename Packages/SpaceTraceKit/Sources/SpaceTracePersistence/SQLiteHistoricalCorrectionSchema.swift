import Foundation
import CryptoKit
import SQLite3

@_spi(Benchmark)
public enum SQLiteHistoricalCorrectionPrototypeScenario: String, Sendable, Codable, CaseIterable {
    case noCorrection = "no-correction"
    case correctionChurn = "correction-churn"
    case legacyOverlap = "v10-v12-overlap"
}

@_spi(Benchmark)
public struct SQLiteHistoricalCorrectionPrototypeResult: Sendable, Codable, Equatable {
    public let scenario: SQLiteHistoricalCorrectionPrototypeScenario
    public let requestedDirectorySamples: Int
    public let retainedV11Nodes: Int
    public let reconciliationRevisionCount: Int
    public let correctingProjectionCount: Int
    public let correctedFindingCount: Int
    public let baseV11Bytes: Int64
    public let preMaintenanceBytes: Int64
    public let mainDatabaseBytes: Int64
    public let walBytes: Int64
    public let shmBytes: Int64
    public let checkpointedBytes: Int64
    public let insertionMilliseconds: Double
    public let terminalRevisionP95Milliseconds: Double
    public let terminalProjectionP95Milliseconds: Double
    public let integrityCheck: String
    public let foreignKeyViolationCount: Int
    public let secureDeleteEnabled: Bool
    public let objectSizes: [SQLiteHistoricalPrototypeObjectSize]
    public let queryPlans: [String]
}

/// Provisional schema-v12 correction layout.
///
/// The schema deliberately reuses immutable v11 observation nodes. A single
/// compact reconciliation row materializes the hourly and daily revisions for
/// one complete node observation; their public IDs are derived from the
/// database-owned node ID plus the bucket discriminator. This avoids copying
/// paths, classification payloads, and both metric endpoints into a second
/// million-row ledger.
@_spi(Benchmark)
public enum SQLiteHistoricalCorrectionSchema {
    static func materializedRevisionID(nodeID: Int64, bucketCode: Int64) throws -> Int64 {
        guard nodeID > 0, nodeID <= Int64.max / 2, bucketCode == 1 || bucketCode == 2 else {
            throw SQLiteHistoricalCorrectionSchemaError.invalidRevisionIdentity
        }
        return nodeID * 2 - (bucketCode == 1 ? 1 : 0)
    }

    static let terminalDailyRevisionCountSQL = """
        SELECT count(*)
        FROM historical_reconciliation_revision revision
        WHERE NOT EXISTS(
            SELECT 1
            FROM historical_reconciliation_revision successor
            WHERE successor.daily_predecessor_node_id=revision.node_id
        )
        """

    static let terminalCorrectingProjectionCountSQL = """
        SELECT count(*)
        FROM historical_correcting_projection projection
        JOIN historical_projection_correction_checkpoint checkpoint
          ON checkpoint.correcting_projection_id=projection.correcting_projection_id
        WHERE NOT EXISTS(
            SELECT 1
            FROM historical_projection_correction_work successor_work
            JOIN historical_correcting_projection successor
              ON successor.work_id=successor_work.work_id
            JOIN historical_projection_correction_checkpoint successor_checkpoint
              ON successor_checkpoint.correcting_projection_id=successor.correcting_projection_id
            WHERE successor_work.predecessor_correcting_projection_id=projection.correcting_projection_id
        )
        """

    static let prototypeObjectNames: Set<String> = Set(
        prototypeTableNames + prototypeIndexNames + prototypeTriggerNames
    )

    static let frozenPrototypeObjectDigest = Data([
        0xE3, 0xFC, 0xBB, 0x2D, 0x62, 0xF3, 0x19, 0xF3,
        0xDD, 0xE2, 0xE1, 0xDE, 0xB1, 0x84, 0xA3, 0x0C,
        0x0A, 0xCD, 0x5A, 0x13, 0x69, 0x1A, 0x2A, 0xE8,
        0xE0, 0xD9, 0x03, 0xEE, 0xF1, 0x79, 0x6B, 0x25,
    ])

    static func installPrototype(on database: OpaquePointer) throws {
        try correctionSchemaExecute(database, "PRAGMA foreign_keys=ON")
        try correctionSchemaExecute(database, schemaSQL)
    }

    static func prototypeObjectDigest(database: OpaquePointer) throws -> Data {
        var statement: OpaquePointer?
        let placeholders = Array(repeating: "?", count: prototypeObjectNames.count)
            .joined(separator: ",")
        let sql = """
            SELECT type,name,tbl_name,sql
            FROM sqlite_schema
            WHERE name IN (\(placeholders))
              AND type IN ('table','index','trigger')
            """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteHistoricalCorrectionSchemaError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, name) in prototypeObjectNames.sorted().enumerated() {
            let result = name.withCString {
                sqlite3_bind_text(statement, Int32(offset + 1), $0, -1, correctionSQLiteTransient)
            }
            guard result == SQLITE_OK else {
                throw SQLiteHistoricalCorrectionSchemaError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
        }

        var objects: [(Data, Data, Data, Data?)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            objects.append((
                try correctionColumnData(statement, 0),
                try correctionColumnData(statement, 1),
                try correctionColumnData(statement, 2),
                sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil
                    : try correctionColumnData(statement, 3)
            ))
        }
        guard objects.count == prototypeObjectNames.count else {
            throw SQLiteHistoricalCorrectionSchemaError.incompleteObjectManifest
        }
        objects.sort { lhs, rhs in
            for pair in [(lhs.0, rhs.0), (lhs.1, rhs.1), (lhs.2, rhs.2)] where pair.0 != pair.1 {
                return pair.0.lexicographicallyPrecedes(pair.1)
            }
            return false
        }
        var canonical = Data()
        correctionAppendLengthPrefixed(
            Data("SpaceTrace.SQLite.v12-correction-object-digest.v1".utf8),
            to: &canonical
        )
        for object in objects {
            correctionAppendLengthPrefixed(object.0, to: &canonical)
            correctionAppendLengthPrefixed(object.1, to: &canonical)
            correctionAppendLengthPrefixed(object.2, to: &canonical)
            if let objectSQL = object.3 {
                canonical.append(0)
                correctionAppendLengthPrefixed(objectSQL, to: &canonical)
            } else {
                canonical.append(0xFF)
            }
        }
        return Data(SHA256.hash(data: canonical))
    }

    @_spi(Benchmark)
    public static func runPrototype(
        databaseURL: URL,
        directorySamples: Int,
        scenario: SQLiteHistoricalCorrectionPrototypeScenario
    ) throws -> SQLiteHistoricalCorrectionPrototypeResult {
        let sameBucketCorrectionCount = scenario == .correctionChurn && directorySamples >= 500_000
            ? directorySamples / 50
            : 0
        let baseDirectorySamples = directorySamples - sameBucketCorrectionCount
        let v11Scenario: SQLiteHistoricalPrototypeScenario
        switch scenario {
        case .noCorrection: v11Scenario = .noChange
        case .correctionChurn: v11Scenario = .twoPercentChurn
        case .legacyOverlap: v11Scenario = .legacyOverlap
        }
        let base = try SQLiteHistoricalFindingSchema.runRepositoryBenchmark(
            databaseURL: databaseURL,
            directorySamples: baseDirectorySamples,
            scenario: v11Scenario
        )

        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else {
            throw SQLiteHistoricalCorrectionSchemaError.sqlite("open correction prototype database")
        }
        defer { sqlite3_close_v2(database) }
        try correctionSchemaExecute(
            database,
            "PRAGMA foreign_keys=ON; PRAGMA secure_delete=ON; PRAGMA cache_size=-8192; PRAGMA temp_store=FILE; PRAGMA mmap_size=0; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;"
        )
        try installPrototype(on: database)

        let started = ContinuousClock.now
        try correctionSchemaExecute(database, "BEGIN IMMEDIATE")
        do {
            let correctionBatch: (batchID: Int64, predecessorBatchID: Int64)?
            if sameBucketCorrectionCount > 0 {
                correctionBatch = try seedSameBucketCorrectionBatch(
                    database,
                    nodeCount: sameBucketCorrectionCount
                )
            } else {
                correctionBatch = nil
            }
            try correctionSchemaExecute(
                database,
                """
                INSERT INTO historical_reconciliation_revision(
                    node_id,hourly_predecessor_node_id,daily_predecessor_node_id,
                    descendant_count,payload_sha256
                )
                SELECT node.node_id,NULL,NULL,0,randomblob(32)
                FROM historical_observation_node node
                JOIN historical_metric_endpoint logical
                  ON logical.node_id=node.node_id AND logical.metric=1
                JOIN historical_metric_endpoint allocated
                  ON allocated.node_id=node.node_id AND allocated.metric=2
                WHERE logical.state_kind=1 AND logical.measurement_coverage=1
                  AND allocated.state_kind=1 AND allocated.measurement_coverage=1
                  AND node.batch_id != \(correctionBatch?.batchID ?? -1)
                ORDER BY node.node_id
                """
            )
            if let correctionBatch {
                try correctionSchemaExecute(
                    database,
                    """
                    INSERT INTO historical_reconciliation_revision(
                        node_id,hourly_predecessor_node_id,daily_predecessor_node_id,
                        descendant_count,payload_sha256
                    )
                    SELECT successor.node_id,predecessor.node_id,predecessor.node_id,0,randomblob(32)
                    FROM historical_observation_node successor
                    JOIN historical_metric_endpoint successor_logical
                      ON successor_logical.node_id=successor.node_id AND successor_logical.metric=1
                    JOIN historical_metric_endpoint successor_allocated
                      ON successor_allocated.node_id=successor.node_id AND successor_allocated.metric=2
                    JOIN historical_observation_node predecessor
                      ON predecessor.batch_id=\(correctionBatch.predecessorBatchID)
                     AND predecessor.subject_key=successor.subject_key
                     AND predecessor.location_key=successor.location_key
                    WHERE successor.batch_id=\(correctionBatch.batchID)
                      AND successor_logical.state_kind=1 AND successor_logical.measurement_coverage=1
                      AND successor_allocated.state_kind=1 AND successor_allocated.measurement_coverage=1
                    ORDER BY successor.node_id
                    """
                )
            }
            if scenario == .correctionChurn {
                try seedCorrectionChurn(database)
            }
            try correctionSchemaExecute(database, "COMMIT")
        } catch {
            try? correctionSchemaExecute(database, "ROLLBACK")
            throw error
        }
        let insertionMilliseconds = correctionElapsedMilliseconds(since: started)
        let preMaintenanceBytes = try correctionDatabaseBytes(databaseURL)

        let terminalRevisionP95Milliseconds = try correctionQueryP95(
            database,
            sql: terminalRevisionBenchmarkSQL
        )
        let terminalProjectionP95Milliseconds = try correctionQueryP95(
            database,
            sql: terminalProjectionBenchmarkSQL
        )

        try correctionSchemaExecute(database, "PRAGMA wal_checkpoint(TRUNCATE); VACUUM; PRAGMA wal_checkpoint(TRUNCATE)")
        let components = try correctionDatabaseComponentBytes(databaseURL)
        let result = SQLiteHistoricalCorrectionPrototypeResult(
            scenario: scenario,
            requestedDirectorySamples: directorySamples,
            retainedV11Nodes: try correctionScalarInt(database, "SELECT count(*) FROM historical_observation_node"),
            reconciliationRevisionCount: try correctionScalarInt(database, "SELECT count(*) FROM historical_reconciliation_revision"),
            correctingProjectionCount: try correctionScalarInt(database, "SELECT count(*) FROM historical_correcting_projection"),
            correctedFindingCount: try correctionScalarInt(database, "SELECT count(*) FROM historical_corrected_finding"),
            baseV11Bytes: base.checkpointedBytes,
            preMaintenanceBytes: preMaintenanceBytes,
            mainDatabaseBytes: components.main,
            walBytes: components.wal,
            shmBytes: components.shm,
            checkpointedBytes: components.main + components.wal + components.shm,
            insertionMilliseconds: insertionMilliseconds,
            terminalRevisionP95Milliseconds: terminalRevisionP95Milliseconds,
            terminalProjectionP95Milliseconds: terminalProjectionP95Milliseconds,
            integrityCheck: try correctionScalarText(database, "PRAGMA integrity_check"),
            foreignKeyViolationCount: try correctionRowCount(database, "PRAGMA foreign_key_check"),
            secureDeleteEnabled: try correctionScalarInt(database, "PRAGMA secure_delete") == 1,
            objectSizes: try correctionObjectSizes(database),
            queryPlans: try correctionQueryPlans(
                database,
                sql: [terminalRevisionBenchmarkSQL, terminalProjectionBenchmarkSQL]
            )
        )
        return result
    }

    private static let terminalRevisionBenchmarkSQL = """
        SELECT revision.node_id
        FROM historical_observation_batch batch
        JOIN historical_observation_node node ON node.batch_id=batch.batch_id
        JOIN historical_reconciliation_revision revision ON revision.node_id=node.node_id
        WHERE batch.batch_id=(
            SELECT max(candidate.batch_id)
            FROM historical_observation_batch candidate
            WHERE candidate.scope_key=batch.scope_key
        )
          AND NOT EXISTS(
              SELECT 1 FROM historical_reconciliation_revision successor
              WHERE successor.daily_predecessor_node_id=revision.node_id
          )
        ORDER BY node.location_key
        LIMIT 100
        """

    private static let terminalProjectionBenchmarkSQL = """
        SELECT terminal.root_projection_id,terminal.correcting_projection_id
        FROM (
            SELECT root.projection_id AS root_projection_id,NULL AS correcting_projection_id
            FROM historical_finding_projection root
            WHERE NOT EXISTS(
                SELECT 1
                FROM historical_projection_correction_work first_work
                JOIN historical_correcting_projection first_projection ON first_projection.work_id=first_work.work_id
                JOIN historical_projection_correction_checkpoint first_checkpoint
                  ON first_checkpoint.correcting_projection_id=first_projection.correcting_projection_id
                WHERE first_work.root_projection_id=root.projection_id
                  AND first_work.predecessor_correcting_projection_id IS NULL
            )
            UNION ALL
            SELECT work.root_projection_id,projection.correcting_projection_id
            FROM historical_projection_correction_work work
            JOIN historical_correcting_projection projection ON projection.work_id=work.work_id
            JOIN historical_projection_correction_checkpoint checkpoint
              ON checkpoint.correcting_projection_id=projection.correcting_projection_id
            WHERE NOT EXISTS(
                SELECT 1
                FROM historical_projection_correction_work successor_work
                JOIN historical_correcting_projection successor ON successor.work_id=successor_work.work_id
                JOIN historical_projection_correction_checkpoint successor_checkpoint
                  ON successor_checkpoint.correcting_projection_id=successor.correcting_projection_id
                WHERE successor_work.predecessor_correcting_projection_id=projection.correcting_projection_id
            )
        ) AS terminal
        ORDER BY terminal.root_projection_id DESC
        LIMIT 10
        """

    private static func seedSameBucketCorrectionBatch(
        _ database: OpaquePointer,
        nodeCount: Int
    ) throws -> (batchID: Int64, predecessorBatchID: Int64) {
        let predecessorBatchID = try correctionScalarInt64(
            database,
            "SELECT max(batch_id) FROM historical_observation_batch"
        )
        let predecessorNodeCount = try correctionScalarInt(
            database,
            "SELECT count(*) FROM historical_observation_node WHERE batch_id=\(predecessorBatchID)"
        )
        guard nodeCount > 0, nodeCount <= predecessorNodeCount else {
            throw SQLiteHistoricalCorrectionSchemaError.invalidCorrectionWorkload
        }
        let observedAt = try correctionScalarInt64(
            database,
            "SELECT max(observed_at_ms)+1000 FROM historical_observation_node WHERE batch_id=\(predecessorBatchID)"
        )
        let runID = "30112233-4455-6677-8899-aabbccddeeff"
        try correctionSchemaExecute(
            database,
            """
            INSERT INTO scan_run(
                id,stream_id,region_path,dirty_revision_be,state,coverage,
                entries_seen,directories_staged,started_at_ms,finished_at_ms
            )
            SELECT '\(runID)',CAST(stream_id_utf8 AS TEXT),'/Fixtures/V12-Reconciliation',
                   X'0000000000000001','completed','complete',\(nodeCount),\(nodeCount),
                   \(observedAt),\(observedAt + 1000)
            FROM historical_observation_batch
            WHERE batch_id=\(predecessorBatchID)
            """
        )
        try correctionSchemaExecute(
            database,
            """
            INSERT INTO historical_observation_batch(
                scan_run_id,stream_id_utf8,scope_key,root_subject_key,volume_id,
                mount_generation_id,coverage_epoch_id,path_semantics_version,
                measurement_semantics_version,created_at_ms
            )
            SELECT '\(runID)',stream_id_utf8,scope_key,root_subject_key,volume_id,
                   mount_generation_id,X'7631322d636f7272656374696f6e',path_semantics_version,
                   measurement_semantics_version,\(observedAt)
            FROM historical_observation_batch
            WHERE batch_id=\(predecessorBatchID)
            """
        )
        let batchID = sqlite3_last_insert_rowid(database)
        let firstFrameID = try correctionScalarInt64(
            database,
            "SELECT coalesce(max(frame_id),0)+1 FROM historical_observation_frame"
        )
        try correctionSchemaExecute(
            database,
            "INSERT INTO historical_observation_frame(frame_id,batch_id,metric) VALUES(\(firstFrameID),\(batchID),1),(\(firstFrameID + 1),\(batchID),2)"
        )
        let predecessorRootNodeID = try correctionScalarInt64(
            database,
            "SELECT node_id FROM historical_observation_node WHERE batch_id=\(predecessorBatchID) AND parent_node_id IS NULL"
        )
        try correctionSchemaExecute(
            database,
            """
            INSERT INTO historical_observation_node(
                batch_id,subject_key,location_key,parent_node_id,observed_at_ms,
                direct_children_coverage,classification_decision_id
            )
            SELECT \(batchID),subject_key,location_key,NULL,\(observedAt),
                   direct_children_coverage,classification_decision_id
            FROM historical_observation_node
            WHERE node_id=\(predecessorRootNodeID)
            """
        )
        let rootNodeID = sqlite3_last_insert_rowid(database)
        if nodeCount > 1 {
            try correctionSchemaExecute(
                database,
                """
                INSERT INTO historical_observation_node(
                    batch_id,subject_key,location_key,parent_node_id,observed_at_ms,
                    direct_children_coverage,classification_decision_id
                )
                SELECT \(batchID),subject_key,location_key,\(rootNodeID),\(observedAt),
                       direct_children_coverage,classification_decision_id
                FROM historical_observation_node
                WHERE batch_id=\(predecessorBatchID) AND parent_node_id IS NOT NULL
                ORDER BY node_id
                LIMIT \(nodeCount - 1)
                """
            )
        }
        try correctionSchemaExecute(
            database,
            """
            INSERT INTO historical_endpoint_stable_identity(
                node_id,guard_kind,generation_token_utf8,birth_seconds,birth_nanoseconds,
                node_kind,link_status
            )
            SELECT successor.node_id,stable.guard_kind,stable.generation_token_utf8,
                   stable.birth_seconds,stable.birth_nanoseconds,stable.node_kind,stable.link_status
            FROM historical_observation_node successor
            JOIN historical_observation_node predecessor
              ON predecessor.batch_id=\(predecessorBatchID)
             AND predecessor.subject_key=successor.subject_key
             AND predecessor.location_key=successor.location_key
            JOIN historical_endpoint_stable_identity stable ON stable.node_id=predecessor.node_id
            WHERE successor.batch_id=\(batchID)
            """
        )
        try correctionSchemaExecute(
            database,
            """
            INSERT INTO historical_metric_endpoint(
                node_id,metric,frame_id,state_kind,bytes,measurement_coverage,unknown_reason_code
            )
            SELECT successor.node_id,endpoint.metric,
                   CASE endpoint.metric WHEN 1 THEN \(firstFrameID) ELSE \(firstFrameID + 1) END,
                   endpoint.state_kind,
                   CASE WHEN endpoint.bytes IS NULL THEN NULL ELSE endpoint.bytes+4096 END,
                   endpoint.measurement_coverage,endpoint.unknown_reason_code
            FROM historical_observation_node successor
            JOIN historical_observation_node predecessor
              ON predecessor.batch_id=\(predecessorBatchID)
             AND predecessor.subject_key=successor.subject_key
             AND predecessor.location_key=successor.location_key
            JOIN historical_metric_endpoint endpoint ON endpoint.node_id=predecessor.node_id
            WHERE successor.batch_id=\(batchID)
            ORDER BY successor.node_id,endpoint.metric
            """
        )
        let expiry = observedAt + 2_592_000_000
        try correctionSchemaExecute(
            database,
            "INSERT INTO historical_observation_frame_commit(frame_id,root_node_id,root_metric,endpoint_count,committed_at_ms,retention_anchor_ms,expires_at_ms) VALUES(\(firstFrameID),\(rootNodeID),1,\(nodeCount),\(observedAt + 1000),\(observedAt),\(expiry))"
        )
        let logicalSequence = sqlite3_last_insert_rowid(database)
        try correctionSchemaExecute(
            database,
            "INSERT INTO historical_observation_frame_commit(frame_id,root_node_id,root_metric,endpoint_count,committed_at_ms,retention_anchor_ms,expires_at_ms) VALUES(\(firstFrameID + 1),\(rootNodeID),2,\(nodeCount),\(observedAt + 1000),\(observedAt),\(expiry))"
        )
        let allocatedSequence = sqlite3_last_insert_rowid(database)
        try correctionExecute(
            database,
            """
            INSERT INTO historical_calibration_receipt(
                scan_run_id,request_format_version,canonical_request_sha256,outcome,
                logical_sequence,allocated_sequence,committed_at_ms,retention_anchor_ms,expires_at_ms
            ) VALUES('\(runID)',1,?,1,\(logicalSequence),\(allocatedSequence),\(observedAt + 1000),\(observedAt),\(expiry))
            """,
            bindings: [.blob(correctionFixedBytes(batchID + 4_000_000, count: 32))]
        )
        return (batchID, predecessorBatchID)
    }

    private static func seedCorrectionChurn(_ database: OpaquePointer) throws {
        let inputDigest = Data(repeating: 0x22, count: 32)
        let inputPayload = Data(repeating: 0x43, count: 64)
        try correctionExecute(
            database,
            "INSERT INTO historical_correction_input(algorithm_version,ranking_policy_version,input_format_version,input_sha256,canonical_input) VALUES(2,1,1,?,?)",
            bindings: [.blob(inputDigest), .blob(inputPayload)]
        )

        let roots = try correctionIntRows(
            database,
            """
            SELECT projection.projection_id
            FROM historical_finding_projection projection
            JOIN historical_projection_checkpoint checkpoint ON checkpoint.work_id=projection.work_id
            ORDER BY projection.projection_id
            """
        )
        for rootProjectionID in roots {
            let requestID = correctionFixedBytes(rootProjectionID, count: 16)
            let requestDigest = correctionFixedBytes(rootProjectionID &+ 1_000_000, count: 32)
            let resultDigest = correctionFixedBytes(rootProjectionID &+ 2_000_000, count: 32)
            let rootDigest = try correctionBlob(
                database,
                sql: "SELECT canonical_result_sha256 FROM historical_finding_projection WHERE projection_id=?",
                integer: rootProjectionID
            )
            try correctionExecute(
                database,
                """
                INSERT INTO historical_projection_correction_work(
                    request_id,request_format_version,canonical_request_sha256,
                    root_projection_id,predecessor_correcting_projection_id,
                    expected_predecessor_sha256,algorithm_version,ranking_policy_version,
                    correction_input_format_version,correction_input_sha256,created_at_ms
                ) VALUES(?,1,?,?,NULL,?,2,1,1,?,2212336800000)
                """,
                bindings: [
                    .blob(requestID), .blob(requestDigest), .integer(rootProjectionID),
                    .blob(rootDigest), .blob(inputDigest),
                ]
            )
            let workID = sqlite3_last_insert_rowid(database)
            let findingCount = try correctionScalarInt(
                database,
                "SELECT count(*) FROM historical_finding WHERE projection_id=\(rootProjectionID)"
            )
            let expiry = try correctionScalarInt64(
                database,
                """
                SELECT min(baseline.expires_at_ms,comparison.expires_at_ms)
                FROM historical_finding_projection projection
                JOIN historical_projection_work work ON work.work_id=projection.work_id
                JOIN historical_observation_frame_commit baseline ON baseline.sequence=work.baseline_sequence
                JOIN historical_observation_frame_commit comparison ON comparison.sequence=work.comparison_sequence
                WHERE projection.projection_id=\(rootProjectionID)
                """
            )
            try correctionExecute(
                database,
                """
                INSERT INTO historical_correcting_projection(
                    work_id,result_format_version,canonical_result_sha256,finding_count,
                    ranked_positive_count,reason_count,truncated_positive_count,
                    committed_at_ms,expires_at_ms
                ) VALUES(?,1,?,?,0,0,0,2212336800000,?)
                """,
                bindings: [
                    .integer(workID), .blob(resultDigest), .integer(Int64(findingCount)),
                    .integer(expiry),
                ]
            )
            let correctingProjectionID = sqlite3_last_insert_rowid(database)
            try correctionExecute(
                database,
                """
                INSERT INTO historical_corrected_finding(
                    correcting_projection_id,ordinal,finding_key_sha256,draft_sha256,
                    baseline_node_id,baseline_metric,comparison_node_id,comparison_metric,
                    kind,inclusive_delta_bytes,ranking_contribution_bytes,
                    movement_ancestor_corrected_finding_id,expires_at_ms
                )
                SELECT ?,ordinal,finding_key_sha256,draft_sha256,
                       baseline_node_id,baseline_metric,comparison_node_id,comparison_metric,
                       kind,inclusive_delta_bytes,ranking_contribution_bytes,NULL,expires_at_ms
                FROM historical_finding
                WHERE projection_id=?
                ORDER BY ordinal
                """,
                bindings: [.integer(correctingProjectionID), .integer(rootProjectionID)]
            )
            try correctionExecute(
                database,
                "INSERT INTO historical_projection_correction_checkpoint(work_id,correcting_projection_id,committed_at_ms) VALUES(?,?,2212336800000)",
                bindings: [.integer(workID), .integer(correctingProjectionID)]
            )
        }
    }

    private static let prototypeTableNames = [
        "historical_reconciliation_revision",
        "historical_correction_input",
        "historical_projection_correction_work",
        "historical_correcting_projection",
        "historical_corrected_finding",
        "historical_corrected_positive_rank",
        "historical_corrected_reason_count",
        "historical_projection_correction_checkpoint",
    ]

    private static let prototypeIndexNames = [
        "historical_reconciliation_hourly_predecessor_unique",
        "historical_reconciliation_daily_predecessor_unique",
        "historical_correction_root_first_unique",
        "historical_correction_predecessor_unique",
        "historical_correction_root_lookup",
        "historical_corrected_finding_baseline_endpoint",
        "historical_corrected_finding_comparison_endpoint",
    ]

    private static let prototypeTriggerNames = [
        "historical_reconciliation_validate_insert",
        "historical_correction_work_validate_insert",
        "historical_correcting_projection_validate_insert",
        "historical_corrected_finding_validate_insert",
        "historical_corrected_rank_validate_insert",
        "historical_corrected_reason_validate_insert",
        "historical_correction_checkpoint_validate_insert",
        "historical_reconciliation_immutable_update",
        "historical_correction_input_immutable_update",
        "historical_correction_work_immutable_update",
        "historical_correcting_projection_immutable_update",
        "historical_corrected_finding_immutable_update",
        "historical_corrected_rank_immutable_update",
        "historical_corrected_reason_immutable_update",
        "historical_correction_checkpoint_immutable_update",
    ]

    private static let schemaSQL = #"""
    CREATE TABLE historical_reconciliation_revision (
        node_id INTEGER PRIMARY KEY REFERENCES historical_observation_node(node_id) ON DELETE RESTRICT,
        hourly_predecessor_node_id INTEGER REFERENCES historical_reconciliation_revision(node_id) ON DELETE RESTRICT,
        daily_predecessor_node_id INTEGER REFERENCES historical_reconciliation_revision(node_id) ON DELETE RESTRICT,
        descendant_count INTEGER NOT NULL CHECK(descendant_count >= 0),
        payload_sha256 BLOB NOT NULL CHECK(typeof(payload_sha256)='blob' AND length(payload_sha256)=32),
        CHECK(hourly_predecessor_node_id IS NULL OR hourly_predecessor_node_id != node_id),
        CHECK(daily_predecessor_node_id IS NULL OR daily_predecessor_node_id != node_id)
    ) WITHOUT ROWID;

    CREATE TABLE historical_correction_input (
        algorithm_version INTEGER NOT NULL CHECK(algorithm_version > 0),
        ranking_policy_version INTEGER NOT NULL CHECK(ranking_policy_version > 0),
        input_format_version INTEGER NOT NULL CHECK(input_format_version > 0),
        input_sha256 BLOB NOT NULL CHECK(typeof(input_sha256)='blob' AND length(input_sha256)=32),
        canonical_input BLOB NOT NULL CHECK(
            typeof(canonical_input)='blob' AND length(canonical_input) BETWEEN 1 AND 65536
        ),
        PRIMARY KEY(algorithm_version,ranking_policy_version,input_format_version,input_sha256)
    ) WITHOUT ROWID;

    CREATE TABLE historical_projection_correction_work (
        work_id INTEGER PRIMARY KEY AUTOINCREMENT,
        request_id BLOB NOT NULL UNIQUE CHECK(typeof(request_id)='blob' AND length(request_id)=16),
        request_format_version INTEGER NOT NULL CHECK(request_format_version=1),
        canonical_request_sha256 BLOB NOT NULL CHECK(
            typeof(canonical_request_sha256)='blob' AND length(canonical_request_sha256)=32
        ),
        root_projection_id INTEGER NOT NULL REFERENCES historical_finding_projection(projection_id) ON DELETE RESTRICT,
        predecessor_correcting_projection_id INTEGER REFERENCES historical_correcting_projection(correcting_projection_id) ON DELETE RESTRICT,
        expected_predecessor_sha256 BLOB NOT NULL CHECK(
            typeof(expected_predecessor_sha256)='blob' AND length(expected_predecessor_sha256)=32
        ),
        algorithm_version INTEGER NOT NULL,
        ranking_policy_version INTEGER NOT NULL,
        correction_input_format_version INTEGER NOT NULL,
        correction_input_sha256 BLOB NOT NULL CHECK(
            typeof(correction_input_sha256)='blob' AND length(correction_input_sha256)=32
        ),
        created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
        FOREIGN KEY(
            algorithm_version,ranking_policy_version,correction_input_format_version,correction_input_sha256
        ) REFERENCES historical_correction_input(
            algorithm_version,ranking_policy_version,input_format_version,input_sha256
        ) ON DELETE RESTRICT
    );

    CREATE TABLE historical_correcting_projection (
        correcting_projection_id INTEGER PRIMARY KEY AUTOINCREMENT,
        work_id INTEGER NOT NULL UNIQUE REFERENCES historical_projection_correction_work(work_id) ON DELETE RESTRICT,
        result_format_version INTEGER NOT NULL CHECK(result_format_version=1),
        canonical_result_sha256 BLOB NOT NULL CHECK(
            typeof(canonical_result_sha256)='blob' AND length(canonical_result_sha256)=32
        ),
        finding_count INTEGER NOT NULL CHECK(finding_count BETWEEN 0 AND 50000),
        ranked_positive_count INTEGER NOT NULL CHECK(ranked_positive_count BETWEEN 0 AND 100),
        reason_count INTEGER NOT NULL CHECK(reason_count BETWEEN 0 AND 38),
        truncated_positive_count INTEGER NOT NULL CHECK(truncated_positive_count >= 0),
        committed_at_ms INTEGER NOT NULL CHECK(committed_at_ms >= 0),
        expires_at_ms INTEGER NOT NULL CHECK(expires_at_ms >= 0),
        CHECK(ranked_positive_count<=finding_count)
    );

    CREATE TABLE historical_corrected_finding (
        corrected_finding_id INTEGER PRIMARY KEY AUTOINCREMENT,
        correcting_projection_id INTEGER NOT NULL REFERENCES historical_correcting_projection(correcting_projection_id) ON DELETE CASCADE,
        ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
        finding_key_sha256 BLOB NOT NULL CHECK(typeof(finding_key_sha256)='blob' AND length(finding_key_sha256)=32),
        draft_sha256 BLOB NOT NULL CHECK(typeof(draft_sha256)='blob' AND length(draft_sha256)=32),
        baseline_node_id INTEGER NOT NULL,
        baseline_metric INTEGER NOT NULL CHECK(baseline_metric IN (1,2)),
        comparison_node_id INTEGER NOT NULL,
        comparison_metric INTEGER NOT NULL CHECK(comparison_metric IN (1,2)),
        kind INTEGER NOT NULL CHECK(kind BETWEEN 1 AND 5),
        inclusive_delta_bytes INTEGER NOT NULL,
        ranking_contribution_bytes INTEGER,
        movement_ancestor_corrected_finding_id INTEGER REFERENCES historical_corrected_finding(corrected_finding_id) DEFERRABLE INITIALLY DEFERRED,
        expires_at_ms INTEGER NOT NULL CHECK(expires_at_ms >= 0),
        UNIQUE(correcting_projection_id,ordinal),
        UNIQUE(correcting_projection_id,finding_key_sha256),
        CHECK(baseline_metric=comparison_metric),
        CHECK(baseline_node_id!=comparison_node_id),
        FOREIGN KEY(baseline_node_id,baseline_metric) REFERENCES historical_metric_endpoint(node_id,metric) ON DELETE RESTRICT,
        FOREIGN KEY(comparison_node_id,comparison_metric) REFERENCES historical_metric_endpoint(node_id,metric) ON DELETE RESTRICT
    );

    CREATE TABLE historical_corrected_positive_rank (
        correcting_projection_id INTEGER NOT NULL REFERENCES historical_correcting_projection(correcting_projection_id) ON DELETE CASCADE,
        rank INTEGER NOT NULL CHECK(rank BETWEEN 1 AND 100),
        corrected_finding_id INTEGER NOT NULL UNIQUE REFERENCES historical_corrected_finding(corrected_finding_id) ON DELETE CASCADE,
        PRIMARY KEY(correcting_projection_id,rank)
    ) WITHOUT ROWID;

    CREATE TABLE historical_corrected_reason_count (
        correcting_projection_id INTEGER NOT NULL REFERENCES historical_correcting_projection(correcting_projection_id) ON DELETE CASCADE,
        category INTEGER NOT NULL CHECK(category BETWEEN 1 AND 3),
        reason_code INTEGER NOT NULL CHECK(
            (category=1 AND reason_code BETWEEN 1 AND 30)
            OR (category=2 AND reason_code BETWEEN 31 AND 34)
            OR (category=3 AND reason_code BETWEEN 35 AND 38)
        ),
        count INTEGER NOT NULL CHECK(count > 0),
        PRIMARY KEY(correcting_projection_id,category,reason_code)
    ) WITHOUT ROWID;

    CREATE TABLE historical_projection_correction_checkpoint (
        work_id INTEGER PRIMARY KEY REFERENCES historical_projection_correction_work(work_id) ON DELETE RESTRICT,
        correcting_projection_id INTEGER NOT NULL UNIQUE REFERENCES historical_correcting_projection(correcting_projection_id) ON DELETE RESTRICT,
        committed_at_ms INTEGER NOT NULL CHECK(committed_at_ms >= 0)
    ) WITHOUT ROWID;

    CREATE UNIQUE INDEX historical_reconciliation_hourly_predecessor_unique
      ON historical_reconciliation_revision(hourly_predecessor_node_id)
      WHERE hourly_predecessor_node_id IS NOT NULL;
    CREATE UNIQUE INDEX historical_reconciliation_daily_predecessor_unique
      ON historical_reconciliation_revision(daily_predecessor_node_id)
      WHERE daily_predecessor_node_id IS NOT NULL;
    CREATE UNIQUE INDEX historical_correction_root_first_unique
      ON historical_projection_correction_work(root_projection_id)
      WHERE predecessor_correcting_projection_id IS NULL;
    CREATE UNIQUE INDEX historical_correction_predecessor_unique
      ON historical_projection_correction_work(predecessor_correcting_projection_id)
      WHERE predecessor_correcting_projection_id IS NOT NULL;
    CREATE INDEX historical_correction_root_lookup
      ON historical_projection_correction_work(root_projection_id,work_id);
    CREATE INDEX historical_corrected_finding_baseline_endpoint
      ON historical_corrected_finding(baseline_node_id,baseline_metric);
    CREATE INDEX historical_corrected_finding_comparison_endpoint
      ON historical_corrected_finding(comparison_node_id,comparison_metric);

    CREATE TRIGGER historical_reconciliation_validate_insert
    BEFORE INSERT ON historical_reconciliation_revision BEGIN
        SELECT CASE WHEN NEW.node_id>4611686018427387903
            THEN RAISE(ABORT,'reconciliation node id exceeds derived identity range') END;
        SELECT CASE WHEN NOT EXISTS(
            SELECT 1
            FROM historical_observation_node node
            JOIN historical_observation_batch batch ON batch.batch_id=node.batch_id
            JOIN scan_run run ON run.id=batch.scan_run_id
            JOIN historical_metric_endpoint logical ON logical.node_id=node.node_id AND logical.metric=1
            JOIN historical_metric_endpoint allocated ON allocated.node_id=node.node_id AND allocated.metric=2
            JOIN historical_observation_frame_commit logical_commit ON logical_commit.frame_id=logical.frame_id
            JOIN historical_observation_frame_commit allocated_commit ON allocated_commit.frame_id=allocated.frame_id
            WHERE node.node_id=NEW.node_id
              AND run.state='completed' AND run.coverage='complete'
              AND logical.state_kind=1 AND logical.measurement_coverage=1
              AND allocated.state_kind=1 AND allocated.measurement_coverage=1
        ) THEN RAISE(ABORT,'reconciliation source is not a complete committed node') END;

        SELECT CASE WHEN NEW.hourly_predecessor_node_id IS NULL AND EXISTS(
            SELECT 1
            FROM historical_reconciliation_revision prior
            JOIN historical_observation_node prior_node ON prior_node.node_id=prior.node_id
            JOIN historical_observation_batch prior_batch ON prior_batch.batch_id=prior_node.batch_id
            JOIN historical_observation_node new_node ON new_node.node_id=NEW.node_id
            JOIN historical_observation_batch new_batch ON new_batch.batch_id=new_node.batch_id
            WHERE prior_batch.scope_key=new_batch.scope_key
              AND prior_batch.stream_id_utf8=new_batch.stream_id_utf8
              AND prior_node.subject_key=new_node.subject_key
              AND prior_node.location_key=new_node.location_key
              AND prior.node_id<NEW.node_id
              AND prior_node.observed_at_ms/3600000=new_node.observed_at_ms/3600000
        ) THEN RAISE(ABORT,'missing hourly reconciliation predecessor') END;
        SELECT CASE WHEN NEW.daily_predecessor_node_id IS NULL AND EXISTS(
            SELECT 1
            FROM historical_reconciliation_revision prior
            JOIN historical_observation_node prior_node ON prior_node.node_id=prior.node_id
            JOIN historical_observation_batch prior_batch ON prior_batch.batch_id=prior_node.batch_id
            JOIN historical_observation_node new_node ON new_node.node_id=NEW.node_id
            JOIN historical_observation_batch new_batch ON new_batch.batch_id=new_node.batch_id
            WHERE prior_batch.scope_key=new_batch.scope_key
              AND prior_batch.stream_id_utf8=new_batch.stream_id_utf8
              AND prior_node.subject_key=new_node.subject_key
              AND prior_node.location_key=new_node.location_key
              AND prior.node_id<NEW.node_id
              AND prior_node.observed_at_ms/86400000=new_node.observed_at_ms/86400000
        ) THEN RAISE(ABORT,'missing daily reconciliation predecessor') END;

        SELECT CASE WHEN NEW.hourly_predecessor_node_id IS NOT NULL AND NOT EXISTS(
            SELECT 1
            FROM historical_reconciliation_revision prior
            JOIN historical_observation_node prior_node ON prior_node.node_id=prior.node_id
            JOIN historical_observation_batch prior_batch ON prior_batch.batch_id=prior_node.batch_id
            JOIN historical_observation_node new_node ON new_node.node_id=NEW.node_id
            JOIN historical_observation_batch new_batch ON new_batch.batch_id=new_node.batch_id
            WHERE prior.node_id=NEW.hourly_predecessor_node_id
              AND prior_batch.scope_key=new_batch.scope_key
              AND prior_batch.stream_id_utf8=new_batch.stream_id_utf8
              AND prior_node.subject_key=new_node.subject_key
              AND prior_node.location_key=new_node.location_key
              AND prior_node.observed_at_ms/3600000=new_node.observed_at_ms/3600000
              AND NOT EXISTS(
                  SELECT 1 FROM historical_reconciliation_revision successor
                  WHERE successor.hourly_predecessor_node_id=prior.node_id
              )
        ) THEN RAISE(ABORT,'invalid hourly reconciliation predecessor') END;
        SELECT CASE WHEN NEW.daily_predecessor_node_id IS NOT NULL AND NOT EXISTS(
            SELECT 1
            FROM historical_reconciliation_revision prior
            JOIN historical_observation_node prior_node ON prior_node.node_id=prior.node_id
            JOIN historical_observation_batch prior_batch ON prior_batch.batch_id=prior_node.batch_id
            JOIN historical_observation_node new_node ON new_node.node_id=NEW.node_id
            JOIN historical_observation_batch new_batch ON new_batch.batch_id=new_node.batch_id
            WHERE prior.node_id=NEW.daily_predecessor_node_id
              AND prior_batch.scope_key=new_batch.scope_key
              AND prior_batch.stream_id_utf8=new_batch.stream_id_utf8
              AND prior_node.subject_key=new_node.subject_key
              AND prior_node.location_key=new_node.location_key
              AND prior_node.observed_at_ms/86400000=new_node.observed_at_ms/86400000
              AND NOT EXISTS(
                  SELECT 1 FROM historical_reconciliation_revision successor
                  WHERE successor.daily_predecessor_node_id=prior.node_id
              )
        ) THEN RAISE(ABORT,'invalid daily reconciliation predecessor') END;
    END;

    CREATE TRIGGER historical_correction_work_validate_insert
    BEFORE INSERT ON historical_projection_correction_work BEGIN
        SELECT CASE WHEN NOT EXISTS(
            SELECT 1
            FROM historical_finding_projection root
            JOIN historical_projection_work root_work ON root_work.work_id=root.work_id
            JOIN historical_projection_checkpoint root_checkpoint ON root_checkpoint.work_id=root_work.work_id
            WHERE root.projection_id=NEW.root_projection_id
        ) THEN RAISE(ABORT,'correction root projection is not committed') END;

        SELECT CASE WHEN NEW.predecessor_correcting_projection_id IS NULL AND NOT EXISTS(
            SELECT 1 FROM historical_finding_projection root
            WHERE root.projection_id=NEW.root_projection_id
              AND root.canonical_result_sha256=NEW.expected_predecessor_sha256
        ) THEN RAISE(ABORT,'stale root projection digest') END;

        SELECT CASE WHEN NEW.predecessor_correcting_projection_id IS NOT NULL AND NOT EXISTS(
            SELECT 1
            FROM historical_correcting_projection predecessor
            JOIN historical_projection_correction_work predecessor_work
              ON predecessor_work.work_id=predecessor.work_id
            JOIN historical_projection_correction_checkpoint predecessor_checkpoint
              ON predecessor_checkpoint.correcting_projection_id=predecessor.correcting_projection_id
            WHERE predecessor.correcting_projection_id=NEW.predecessor_correcting_projection_id
              AND predecessor_work.root_projection_id=NEW.root_projection_id
              AND predecessor.canonical_result_sha256=NEW.expected_predecessor_sha256
              AND NOT EXISTS(
                  SELECT 1
                  FROM historical_projection_correction_work successor
                  WHERE successor.predecessor_correcting_projection_id=predecessor.correcting_projection_id
              )
        ) THEN RAISE(ABORT,'invalid correcting projection predecessor') END;

        SELECT CASE WHEN NEW.predecessor_correcting_projection_id IS NOT NULL AND EXISTS(
            SELECT 1
            FROM historical_correcting_projection predecessor
            JOIN historical_projection_correction_work predecessor_work
              ON predecessor_work.work_id=predecessor.work_id
            WHERE predecessor.correcting_projection_id=NEW.predecessor_correcting_projection_id
              AND predecessor_work.algorithm_version=NEW.algorithm_version
              AND predecessor_work.ranking_policy_version=NEW.ranking_policy_version
              AND predecessor_work.correction_input_format_version=NEW.correction_input_format_version
              AND predecessor_work.correction_input_sha256=NEW.correction_input_sha256
        ) THEN RAISE(ABORT,'correction semantic identity unchanged') END;
    END;

    CREATE TRIGGER historical_correcting_projection_validate_insert
    BEFORE INSERT ON historical_correcting_projection BEGIN
        SELECT CASE WHEN NOT EXISTS(
            SELECT 1
            FROM historical_projection_correction_work work
            JOIN historical_finding_projection root ON root.projection_id=work.root_projection_id
            JOIN historical_projection_work root_work ON root_work.work_id=root.work_id
            JOIN historical_observation_frame_commit baseline ON baseline.sequence=root_work.baseline_sequence
            JOIN historical_observation_frame_commit comparison ON comparison.sequence=root_work.comparison_sequence
            WHERE work.work_id=NEW.work_id
              AND NEW.expires_at_ms=min(baseline.expires_at_ms,comparison.expires_at_ms)
        ) THEN RAISE(ABORT,'correcting projection frame expiry mismatch') END;
    END;

    CREATE TRIGGER historical_corrected_finding_validate_insert
    BEFORE INSERT ON historical_corrected_finding BEGIN
        SELECT CASE WHEN EXISTS(
            SELECT 1 FROM historical_projection_correction_checkpoint checkpoint
            WHERE checkpoint.correcting_projection_id=NEW.correcting_projection_id
        ) THEN RAISE(ABORT,'correcting projection already committed') END;
        SELECT CASE WHEN NOT EXISTS(
            SELECT 1
            FROM historical_correcting_projection projection
            JOIN historical_projection_correction_work correction_work ON correction_work.work_id=projection.work_id
            JOIN historical_finding_projection root ON root.projection_id=correction_work.root_projection_id
            JOIN historical_projection_work root_work ON root_work.work_id=root.work_id
            JOIN historical_observation_frame_commit baseline_commit ON baseline_commit.sequence=root_work.baseline_sequence
            JOIN historical_observation_frame_commit comparison_commit ON comparison_commit.sequence=root_work.comparison_sequence
            JOIN historical_observation_frame baseline_frame ON baseline_frame.frame_id=baseline_commit.frame_id
            JOIN historical_observation_frame comparison_frame ON comparison_frame.frame_id=comparison_commit.frame_id
            JOIN historical_observation_node baseline_node ON baseline_node.node_id=NEW.baseline_node_id AND baseline_node.batch_id=baseline_frame.batch_id
            JOIN historical_observation_node comparison_node ON comparison_node.node_id=NEW.comparison_node_id AND comparison_node.batch_id=comparison_frame.batch_id
            WHERE projection.correcting_projection_id=NEW.correcting_projection_id
              AND baseline_frame.metric=NEW.baseline_metric
              AND comparison_frame.metric=NEW.comparison_metric
              AND NEW.expires_at_ms=projection.expires_at_ms
        ) THEN RAISE(ABORT,'corrected finding frame mismatch') END;
        SELECT CASE WHEN NEW.movement_ancestor_corrected_finding_id IS NOT NULL AND NOT EXISTS(
            SELECT 1 FROM historical_corrected_finding ancestor
            WHERE ancestor.corrected_finding_id=NEW.movement_ancestor_corrected_finding_id
              AND ancestor.correcting_projection_id=NEW.correcting_projection_id
              AND ancestor.kind=5
        ) THEN RAISE(ABORT,'corrected movement ancestor mismatch') END;
    END;

    CREATE TRIGGER historical_corrected_rank_validate_insert
    BEFORE INSERT ON historical_corrected_positive_rank BEGIN
        SELECT CASE WHEN EXISTS(
            SELECT 1 FROM historical_projection_correction_checkpoint checkpoint
            WHERE checkpoint.correcting_projection_id=NEW.correcting_projection_id
        ) THEN RAISE(ABORT,'correcting projection already committed') END;
        SELECT CASE WHEN NOT EXISTS(
            SELECT 1
            FROM historical_corrected_finding finding
            JOIN historical_correcting_projection projection
              ON projection.correcting_projection_id=finding.correcting_projection_id
            JOIN historical_projection_correction_work correction_work ON correction_work.work_id=projection.work_id
            JOIN historical_finding_projection root ON root.projection_id=correction_work.root_projection_id
            JOIN historical_projection_work root_work ON root_work.work_id=root.work_id
            WHERE finding.corrected_finding_id=NEW.corrected_finding_id
              AND finding.correcting_projection_id=NEW.correcting_projection_id
              AND NEW.rank<=root_work.positive_limit
              AND finding.kind IN (1,4)
              AND finding.ranking_contribution_bytes>0
        ) THEN RAISE(ABORT,'corrected rank mismatch') END;
    END;

    CREATE TRIGGER historical_corrected_reason_validate_insert
    BEFORE INSERT ON historical_corrected_reason_count BEGIN
        SELECT CASE WHEN EXISTS(
            SELECT 1 FROM historical_projection_correction_checkpoint checkpoint
            WHERE checkpoint.correcting_projection_id=NEW.correcting_projection_id
        ) THEN RAISE(ABORT,'correcting projection already committed') END;
    END;

    CREATE TRIGGER historical_correction_checkpoint_validate_insert
    BEFORE INSERT ON historical_projection_correction_checkpoint BEGIN
        SELECT CASE WHEN NOT EXISTS(
            SELECT 1 FROM historical_correcting_projection projection
            WHERE projection.correcting_projection_id=NEW.correcting_projection_id
              AND projection.work_id=NEW.work_id
              AND projection.committed_at_ms=NEW.committed_at_ms
              AND projection.finding_count=(
                  SELECT count(*) FROM historical_corrected_finding finding
                  WHERE finding.correcting_projection_id=projection.correcting_projection_id
              )
              AND (
                  projection.finding_count=0
                  OR (SELECT min(ordinal) FROM historical_corrected_finding finding
                      WHERE finding.correcting_projection_id=projection.correcting_projection_id)=0
              )
              AND (
                  projection.finding_count=0
                  OR (SELECT max(ordinal) FROM historical_corrected_finding finding
                      WHERE finding.correcting_projection_id=projection.correcting_projection_id)
                     =projection.finding_count-1
              )
              AND projection.ranked_positive_count=(
                  SELECT count(*) FROM historical_corrected_positive_rank rank
                  WHERE rank.correcting_projection_id=projection.correcting_projection_id
              )
              AND (
                  projection.ranked_positive_count=0
                  OR (SELECT min(rank) FROM historical_corrected_positive_rank ranked
                      WHERE ranked.correcting_projection_id=projection.correcting_projection_id)=1
              )
              AND (
                  projection.ranked_positive_count=0
                  OR (SELECT max(rank) FROM historical_corrected_positive_rank ranked
                      WHERE ranked.correcting_projection_id=projection.correcting_projection_id)
                     =projection.ranked_positive_count
              )
              AND projection.reason_count=(
                  SELECT count(*) FROM historical_corrected_reason_count reason
                  WHERE reason.correcting_projection_id=projection.correcting_projection_id
              )
        ) THEN RAISE(ABORT,'incomplete correcting projection') END;
    END;

    CREATE TRIGGER historical_reconciliation_immutable_update BEFORE UPDATE ON historical_reconciliation_revision BEGIN SELECT RAISE(ABORT,'immutable historical reconciliation revision'); END;
    CREATE TRIGGER historical_correction_input_immutable_update BEFORE UPDATE ON historical_correction_input BEGIN SELECT RAISE(ABORT,'immutable historical correction input'); END;
    CREATE TRIGGER historical_correction_work_immutable_update BEFORE UPDATE ON historical_projection_correction_work BEGIN SELECT RAISE(ABORT,'immutable historical correction work'); END;
    CREATE TRIGGER historical_correcting_projection_immutable_update BEFORE UPDATE ON historical_correcting_projection BEGIN SELECT RAISE(ABORT,'immutable historical correcting projection'); END;
    CREATE TRIGGER historical_corrected_finding_immutable_update BEFORE UPDATE ON historical_corrected_finding BEGIN SELECT RAISE(ABORT,'immutable historical corrected finding'); END;
    CREATE TRIGGER historical_corrected_rank_immutable_update BEFORE UPDATE ON historical_corrected_positive_rank BEGIN SELECT RAISE(ABORT,'immutable historical corrected rank'); END;
    CREATE TRIGGER historical_corrected_reason_immutable_update BEFORE UPDATE ON historical_corrected_reason_count BEGIN SELECT RAISE(ABORT,'immutable historical corrected reason'); END;
    CREATE TRIGGER historical_correction_checkpoint_immutable_update BEFORE UPDATE ON historical_projection_correction_checkpoint BEGIN SELECT RAISE(ABORT,'immutable historical correction checkpoint'); END;
    """#
}

private func correctionSchemaExecute(_ database: OpaquePointer, _ sql: String) throws {
    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &message)
    defer { sqlite3_free(message) }
    guard result == SQLITE_OK else {
        throw SQLiteHistoricalCorrectionSchemaError.sqlite(
            message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
        )
    }
}

private enum CorrectionSchemaBinding {
    case integer(Int64)
    case blob(Data)
}

private func correctionExecute(
    _ database: OpaquePointer,
    _ sql: String,
    bindings: [CorrectionSchemaBinding]
) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw SQLiteHistoricalCorrectionSchemaError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    for (offset, binding) in bindings.enumerated() {
        let index = Int32(offset + 1)
        switch binding {
        case let .integer(value):
            guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
                throw SQLiteHistoricalCorrectionSchemaError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
        case let .blob(value):
            let result = value.withUnsafeBytes { buffer in
                sqlite3_bind_blob(
                    statement,
                    index,
                    buffer.baseAddress,
                    Int32(value.count),
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
            guard result == SQLITE_OK else {
                throw SQLiteHistoricalCorrectionSchemaError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
        }
    }
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw SQLiteHistoricalCorrectionSchemaError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
}

private func correctionIntRows(_ database: OpaquePointer, _ sql: String) throws -> [Int64] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw SQLiteHistoricalCorrectionSchemaError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    var values: [Int64] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        values.append(sqlite3_column_int64(statement, 0))
    }
    return values
}

private func correctionBlob(
    _ database: OpaquePointer,
    sql: String,
    integer: Int64
) throws -> Data {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement,
          sqlite3_bind_int64(statement, 1, integer) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW else {
        throw SQLiteHistoricalCorrectionSchemaError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    guard let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
}

private func correctionScalarText(_ database: OpaquePointer, _ sql: String) throws -> String {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement,
          sqlite3_step(statement) == SQLITE_ROW,
          let value = sqlite3_column_text(statement, 0) else {
        throw SQLiteHistoricalCorrectionSchemaError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    return String(cString: value)
}

private func correctionScalarInt(_ database: OpaquePointer, _ sql: String) throws -> Int {
    Int(try correctionScalarInt64(database, sql))
}

private func correctionScalarInt64(_ database: OpaquePointer, _ sql: String) throws -> Int64 {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement,
          sqlite3_step(statement) == SQLITE_ROW else {
        throw SQLiteHistoricalCorrectionSchemaError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    return sqlite3_column_int64(statement, 0)
}

private func correctionRowCount(_ database: OpaquePointer, _ sql: String) throws -> Int {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw SQLiteHistoricalCorrectionSchemaError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    var count = 0
    while sqlite3_step(statement) == SQLITE_ROW { count += 1 }
    return count
}

private func correctionFixedBytes(_ value: Int64, count: Int) -> Data {
    var bigEndian = value.bigEndian
    let word = withUnsafeBytes(of: &bigEndian) { Data($0) }
    var result = Data(capacity: count)
    while result.count < count { result.append(word) }
    return result.prefix(count)
}

private func correctionDatabaseComponentBytes(
    _ databaseURL: URL
) throws -> (main: Int64, wal: Int64, shm: Int64) {
    func size(_ suffix: String) throws -> Int64 {
        let path = databaseURL.path + suffix
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
    return try (size(""), size("-wal"), size("-shm"))
}

private func correctionDatabaseBytes(_ databaseURL: URL) throws -> Int64 {
    let components = try correctionDatabaseComponentBytes(databaseURL)
    return components.main + components.wal + components.shm
}

private func correctionElapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now)
    return Double(duration.components.seconds) * 1_000
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000
}

private func correctionQueryP95(_ database: OpaquePointer, sql: String) throws -> Double {
    var samples: [Double] = []
    for _ in 0..<15 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteHistoricalCorrectionSchemaError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        let started = ContinuousClock.now
        while sqlite3_step(statement) == SQLITE_ROW {}
        samples.append(correctionElapsedMilliseconds(since: started))
        sqlite3_finalize(statement)
    }
    samples.sort()
    let index = min(samples.count - 1, Int((Double(samples.count) * 0.95).rounded(.up)) - 1)
    return samples[max(0, index)]
}

private func correctionObjectSizes(
    _ database: OpaquePointer
) throws -> [SQLiteHistoricalPrototypeObjectSize] {
    var statement: OpaquePointer?
    let sql = """
        SELECT name,sum(pgsize)
        FROM dbstat
        WHERE name LIKE 'historical_reconciliation_%'
           OR name LIKE 'historical_correction_%'
           OR name LIKE 'historical_projection_correction_%'
           OR name LIKE 'historical_correcting_%'
           OR name LIKE 'historical_corrected_%'
        GROUP BY name
        ORDER BY name
        """
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw SQLiteHistoricalCorrectionSchemaError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    var values: [SQLiteHistoricalPrototypeObjectSize] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        guard let name = sqlite3_column_text(statement, 0) else { continue }
        values.append(
            SQLiteHistoricalPrototypeObjectSize(
                name: String(cString: name),
                bytes: sqlite3_column_int64(statement, 1)
            )
        )
    }
    return values
}

private func correctionQueryPlans(
    _ database: OpaquePointer,
    sql statements: [String]
) throws -> [String] {
    var result: [String] = []
    for sql in statements {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "EXPLAIN QUERY PLAN \(sql)", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteHistoricalCorrectionSchemaError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let detail = sqlite3_column_text(statement, 3) {
                result.append(String(cString: detail))
            }
        }
        sqlite3_finalize(statement)
    }
    return result
}

private func correctionColumnData(_ statement: OpaquePointer, _ column: Int32) throws -> Data {
    guard let bytes = sqlite3_column_blob(statement, column) else {
        throw SQLiteHistoricalCorrectionSchemaError.sqlite("missing schema object bytes")
    }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
}

private func correctionAppendLengthPrefixed(_ value: Data, to output: inout Data) {
    var length = UInt64(value.count).bigEndian
    withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
    output.append(value)
}

private let correctionSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteHistoricalCorrectionSchemaError: Error {
    case sqlite(String)
    case incompleteObjectManifest
    case invalidRevisionIdentity
    case invalidCorrectionWorkload
}
