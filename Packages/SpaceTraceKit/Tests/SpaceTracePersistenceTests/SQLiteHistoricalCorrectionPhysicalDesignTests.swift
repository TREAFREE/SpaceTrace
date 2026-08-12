import Foundation
import SQLite3
import Testing
@_spi(Benchmark) @testable import SpaceTracePersistence

@Suite("SQLite v12 reconciliation correction physical design", .serialized)
struct SQLiteHistoricalCorrectionPhysicalDesignTests {
    @Test("One database node deterministically owns distinct hourly and daily revision IDs")
    func derivesBoundedRevisionIdentities() throws {
        #expect(try SQLiteHistoricalCorrectionSchema.materializedRevisionID(nodeID: 1, bucketCode: 1) == 1)
        #expect(try SQLiteHistoricalCorrectionSchema.materializedRevisionID(nodeID: 1, bucketCode: 2) == 2)
        #expect(
            try SQLiteHistoricalCorrectionSchema.materializedRevisionID(
                nodeID: Int64.max / 2,
                bucketCode: 2
            ) == Int64.max - 1
        )
        #expect(throws: SQLiteHistoricalCorrectionSchemaError.self) {
            try SQLiteHistoricalCorrectionSchema.materializedRevisionID(
                nodeID: Int64.max / 2 + 1,
                bucketCode: 1
            )
        }
        #expect(throws: SQLiteHistoricalCorrectionSchemaError.self) {
            try SQLiteHistoricalCorrectionSchema.materializedRevisionID(nodeID: 1, bucketCode: 3)
        }
    }

    @Test(
        "The repository-owned prototype closes every small deterministic workload",
        arguments: SQLiteHistoricalCorrectionPrototypeScenario.allCases
    )
    func runsSmallPrototype(
        scenario: SQLiteHistoricalCorrectionPrototypeScenario
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpaceTrace-v12-small-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("SpaceTrace.sqlite")
        let repository = try SQLiteEventJournalRepository(databaseURL: databaseURL)
        try await repository.close()

        let result = try SQLiteHistoricalCorrectionSchema.runPrototype(
            databaseURL: databaseURL,
            directorySamples: 250,
            scenario: scenario
        )

        #expect(result.retainedV11Nodes == (scenario == .legacyOverlap ? 125 : 250))
        #expect(result.reconciliationRevisionCount > 0)
        #expect((result.correctingProjectionCount > 0) == (scenario == .correctionChurn))
        #expect(result.integrityCheck == "ok")
        #expect(result.foreignKeyViolationCount == 0)
        #expect(result.secureDeleteEnabled)
        #expect(result.queryPlans.isEmpty == false)
        #expect(result.checkpointedBytes >= result.baseV11Bytes)
    }

    @Test("The prototype creates the exact v12 object manifest")
    func createsExactObjectManifest() throws {
        try withCorrectionDatabase { database in
            #expect(SQLiteHistoricalCorrectionSchema.prototypeObjectNames == expectedCorrectionObjects)
            let names = try correctionSchemaObjects(database)
            for name in expectedCorrectionObjects {
                #expect(names.contains(name), "Missing schema object: \(name)")
            }
            let actualDigest = try SQLiteHistoricalCorrectionSchema.prototypeObjectDigest(database: database)
            #expect(actualDigest == SQLiteHistoricalCorrectionSchema.frozenPrototypeObjectDigest)
            #expect(try correctionScalarText(database, "PRAGMA integrity_check") == "ok")
            #expect(try correctionForeignKeyViolationCount(database) == 0)
        }
    }

    @Test("Same-bucket revisions form one immutable terminal chain")
    func enforcesLinearRevisionChains() throws {
        try withCorrectionDatabase { database in
            try seedThreeCompleteBatches(database)
            try insertRevision(database, nodeID: 1, hourlyPredecessor: nil, dailyPredecessor: nil)
            try insertRevision(database, nodeID: 2, hourlyPredecessor: 1, dailyPredecessor: 1)

            #expect(try correctionScalarInt(database, "SELECT count(*) FROM historical_reconciliation_revision") == 2)
            #expect(try correctionScalarInt(database, SQLiteHistoricalCorrectionSchema.terminalDailyRevisionCountSQL) == 1)
            try correctionExpectRejected(database, "UPDATE historical_reconciliation_revision SET descendant_count=9 WHERE node_id=2")
            try correctionExpectRejected(
                database,
                "INSERT INTO historical_reconciliation_revision(node_id,hourly_predecessor_node_id,daily_predecessor_node_id,descendant_count,payload_sha256) VALUES(3,1,1,0,randomblob(32))"
            )
        }
    }

    @Test("Revision predecessors cannot cross an exact scope, stream, subject, location, or bucket key")
    func rejectsIncompatibleRevisionPredecessors() throws {
        try withCorrectionDatabase { database in
            try seedThreeCompleteBatches(database, thirdLocationKey: 2)
            try insertRevision(database, nodeID: 1, hourlyPredecessor: nil, dailyPredecessor: nil)
            try correctionExpectRejected(
                database,
                "INSERT INTO historical_reconciliation_revision(node_id,hourly_predecessor_node_id,daily_predecessor_node_id,descendant_count,payload_sha256) VALUES(3,1,1,0,randomblob(32))"
            )
            try correctionExpectRejected(
                database,
                "INSERT INTO historical_reconciliation_revision(node_id,hourly_predecessor_node_id,daily_predecessor_node_id,descendant_count,payload_sha256) VALUES(1,1,1,0,randomblob(32))"
            )
        }
    }

    @Test("A correcting projection is a complete checkpointed replacement of one exact frame pair")
    func commitsCompleteCorrectingProjection() throws {
        try withCorrectionDatabase { database in
            try seedThreeCompleteBatches(database)
            try seedRootProjection(database)
            try insertCorrectionInput(database, algorithm: 2, byte: 0x21)
            try insertCorrectionWork(database, workID: 1, predecessorCorrectionID: nil, algorithm: 2, expectedByte: 0x11)
            try insertCorrectingProjection(database, projectionID: 1, workID: 1, resultByte: 0x31, findingCount: 0)
            try correctionExecute(
                database,
                "INSERT INTO historical_projection_correction_checkpoint(work_id,correcting_projection_id,committed_at_ms) VALUES(1,1,7200200)"
            )

            #expect(try correctionScalarInt(database, "SELECT count(*) FROM historical_projection_correction_checkpoint") == 1)
            #expect(try correctionScalarInt(database, SQLiteHistoricalCorrectionSchema.terminalCorrectingProjectionCountSQL) == 1)
            try correctionExpectRejected(database, "UPDATE historical_correcting_projection SET finding_count=1 WHERE correcting_projection_id=1")
            try correctionExpectRejected(
                database,
                "INSERT INTO historical_corrected_reason_count(correcting_projection_id,category,reason_code,count) VALUES(1,1,1,1)"
            )
        }
    }

    @Test("Correction work rejects branches, stale digests, and incompatible frame ownership")
    func rejectsInvalidCorrectionEdges() throws {
        try withCorrectionDatabase { database in
            try seedThreeCompleteBatches(database)
            try seedRootProjection(database)
            try insertCorrectionInput(database, algorithm: 2, byte: 0x21)
            try insertCorrectionWork(database, workID: 1, predecessorCorrectionID: nil, algorithm: 2, expectedByte: 0x11)
            try insertCorrectingProjection(database, projectionID: 1, workID: 1, resultByte: 0x31, findingCount: 0)
            try correctionExecute(database, "INSERT INTO historical_projection_correction_checkpoint VALUES(1,1,7200200)")
            try insertCorrectionInput(database, algorithm: 3, byte: 0x22)

            try correctionExpectRejected(
                database,
                correctionWorkSQL(workID: 2, requestByte: 0x42, predecessorCorrectionID: 1, algorithm: 3, expectedByte: 0x30)
            )
            try insertCorrectionWork(database, workID: 2, predecessorCorrectionID: 1, algorithm: 3, expectedByte: 0x31)
            try correctionExpectRejected(
                database,
                correctionWorkSQL(workID: 3, requestByte: 0x43, predecessorCorrectionID: 1, algorithm: 3, expectedByte: 0x31)
            )
            try insertCorrectingProjection(database, projectionID: 2, workID: 2, resultByte: 0x32, findingCount: 0)
            try correctionExecute(database, "INSERT INTO historical_projection_correction_checkpoint VALUES(2,2,7200200)")
            #expect(try correctionScalarInt(database, SQLiteHistoricalCorrectionSchema.terminalCorrectingProjectionCountSQL) == 1)
            try correctionExpectRejected(
                database,
                "INSERT INTO historical_projection_correction_work(work_id,request_id,request_format_version,canonical_request_sha256,root_projection_id,predecessor_correcting_projection_id,expected_predecessor_sha256,algorithm_version,ranking_policy_version,correction_input_format_version,correction_input_sha256,created_at_ms) VALUES(4,randomblob(16),1,randomblob(32),1,NULL,X'11',99,1,1,randomblob(32),1)"
            )
        }
    }

    @Test("A correction checkpoint rejects a partial replacement")
    func rejectsIncompleteCorrectionCheckpoint() throws {
        try withCorrectionDatabase { database in
            try seedThreeCompleteBatches(database)
            try seedRootProjection(database)
            try insertCorrectionInput(database, algorithm: 2, byte: 0x21)
            try insertCorrectionWork(database, workID: 1, predecessorCorrectionID: nil, algorithm: 2, expectedByte: 0x11)
            try insertCorrectingProjection(
                database,
                projectionID: 1,
                workID: 1,
                resultByte: 0x31,
                findingCount: 1,
                rankedPositiveCount: 1,
                reasonCount: 1
            )
            try correctionExecute(
                database,
                "INSERT INTO historical_corrected_finding(corrected_finding_id,correcting_projection_id,ordinal,finding_key_sha256,draft_sha256,baseline_node_id,baseline_metric,comparison_node_id,comparison_metric,kind,inclusive_delta_bytes,ranking_contribution_bytes,movement_ancestor_corrected_finding_id,expires_at_ms) VALUES(1,1,0,randomblob(32),randomblob(32),1,1,2,1,4,1,1,NULL,2599200000)"
            )
            try correctionExpectRejected(
                database,
                "INSERT INTO historical_projection_correction_checkpoint VALUES(1,1,7200200)"
            )
        }
    }
}

private let expectedCorrectionObjects: Set<String> = [
    "historical_reconciliation_revision",
    "historical_correction_input",
    "historical_projection_correction_work",
    "historical_correcting_projection",
    "historical_corrected_finding",
    "historical_corrected_positive_rank",
    "historical_corrected_reason_count",
    "historical_projection_correction_checkpoint",
    "historical_reconciliation_hourly_predecessor_unique",
    "historical_reconciliation_daily_predecessor_unique",
    "historical_correction_root_first_unique",
    "historical_correction_predecessor_unique",
    "historical_correction_root_lookup",
    "historical_corrected_finding_baseline_endpoint",
    "historical_corrected_finding_comparison_endpoint",
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

private func withCorrectionDatabase(_ body: (OpaquePointer) throws -> Void) throws {
    var database: OpaquePointer?
    guard sqlite3_open(":memory:", &database) == SQLITE_OK, let database else {
        throw CorrectionPhysicalDesignTestError.sqlite("open")
    }
    defer { sqlite3_close(database) }
    try correctionExecute(database, "PRAGMA foreign_keys=ON")
    try correctionExecute(database, "CREATE TABLE scan_run(id TEXT PRIMARY KEY,state TEXT NOT NULL DEFAULT 'completed',coverage TEXT NOT NULL DEFAULT 'complete',dirty_revision_be BLOB NOT NULL DEFAULT (zeroblob(8)))")
    try correctionExecute(database, "CREATE TABLE node_current(last_scan_run_id TEXT REFERENCES scan_run(id))")
    try SQLiteHistoricalFindingSchema.installPrototype(on: database)
    try SQLiteHistoricalCorrectionSchema.installPrototype(on: database)
    try body(database)
}

private func seedThreeCompleteBatches(
    _ database: OpaquePointer,
    thirdLocationKey: Int = 1
) throws {
    try correctionExecute(database, "INSERT INTO historical_store_identity VALUES(1,1,X'00112233445566778899aabbccddeeff')")
    try correctionExecute(database, "INSERT INTO historical_scope(scope_key,scope_id) VALUES(1,X'73636f7065')")
    try correctionExecute(database, "INSERT INTO historical_subject(subject_key,scope_key,identity_basis,subject_id) VALUES(1,1,1,X'7375626a656374')")
    try correctionExecute(database, "INSERT INTO historical_location(location_key,scope_key,path_semantics_version,location_id,path_utf8,display_name_utf8) VALUES(1,1,1,X'6c6f636174696f6e',X'2f526f6f74',X'526f6f74'),(2,1,1,X'6f74686572',X'2f4f74686572',X'4f74686572')")
    try correctionExecute(database, "INSERT INTO frozen_attribution_decision(decision_id,format_version,canonical_payload,canonical_sha256,catalog_version,decision_kind,category_code,confidence_code,rule_id,rule_version,evidence_code) VALUES(1,1,X'01',randomblob(32),1,2,NULL,NULL,NULL,NULL,NULL)")

    let runIDs = [
        "00112233-4455-6677-8899-aabbccddeeff",
        "10112233-4455-6677-8899-aabbccddeeff",
        "20112233-4455-6677-8899-aabbccddeeff",
    ]
    for index in 0..<3 {
        let batchID = index + 1
        let nodeID = index + 1
        let observedAt = 7_200_000 + index * 100
        let locationKey = index == 2 ? thirdLocationKey : 1
        try correctionExecute(database, "INSERT INTO scan_run(id) VALUES('\(runIDs[index])')")
        try correctionExecute(database, "INSERT INTO historical_observation_batch(batch_id,scan_run_id,stream_id_utf8,scope_key,root_subject_key,volume_id,mount_generation_id,coverage_epoch_id,path_semantics_version,measurement_semantics_version,created_at_ms) VALUES(\(batchID),'\(runIDs[index])',X'73747265616d',1,1,X'766f6c756d65',X'6d6f756e74',X'65706f6368',1,1,\(observedAt))")
        try correctionExecute(database, "INSERT INTO historical_observation_frame(frame_id,batch_id,metric) VALUES(\(batchID * 2 - 1),\(batchID),1),(\(batchID * 2),\(batchID),2)")
        try correctionExecute(database, "INSERT INTO historical_observation_node(node_id,batch_id,subject_key,location_key,parent_node_id,observed_at_ms,direct_children_coverage,classification_decision_id) VALUES(\(nodeID),\(batchID),1,\(locationKey),NULL,\(observedAt),1,1)")
        try correctionExecute(database, "INSERT INTO historical_endpoint_stable_identity(node_id,guard_kind,generation_token_utf8,birth_seconds,birth_nanoseconds,node_kind,link_status) VALUES(\(nodeID),1,X'67656e65726174696f6e',NULL,NULL,1,1)")
        try correctionExecute(database, "INSERT INTO historical_metric_endpoint(node_id,metric,frame_id,state_kind,bytes,measurement_coverage,unknown_reason_code) VALUES(\(nodeID),1,\(batchID * 2 - 1),1,\(100 + index),1,NULL),(\(nodeID),2,\(batchID * 2),1,\(200 + index),1,NULL)")
        let expiry = observedAt + 2_592_000_000
        try correctionExecute(database, "INSERT INTO historical_observation_frame_commit(sequence,frame_id,root_node_id,root_metric,endpoint_count,committed_at_ms,retention_anchor_ms,expires_at_ms) VALUES(\(batchID * 2 - 1),\(batchID * 2 - 1),\(nodeID),1,1,\(observedAt),\(observedAt),\(expiry)),(\(batchID * 2),\(batchID * 2),\(nodeID),2,1,\(observedAt),\(observedAt),\(expiry))")
    }
}

private func seedRootProjection(_ database: OpaquePointer) throws {
    try correctionExecute(database, "INSERT INTO historical_projection_work(work_id,baseline_sequence,comparison_sequence,algorithm_version,ranking_policy_version,positive_limit,created_at_ms) VALUES(1,1,3,1,1,10,7200200)")
    try correctionExecute(database, "INSERT INTO historical_finding_projection(projection_id,work_id,format_version,canonical_result_sha256,truncated_positive_count,committed_at_ms) VALUES(1,1,1,\(hexBlob(0x11, count: 32)),0,7200200)")
    try correctionExecute(database, "INSERT INTO historical_projection_checkpoint(work_id,committed_at_ms) VALUES(1,7200200)")
}

private func insertRevision(
    _ database: OpaquePointer,
    nodeID: Int,
    hourlyPredecessor: Int?,
    dailyPredecessor: Int?
) throws {
    try correctionExecute(
        database,
        "INSERT INTO historical_reconciliation_revision(node_id,hourly_predecessor_node_id,daily_predecessor_node_id,descendant_count,payload_sha256) VALUES(\(nodeID),\(hourlyPredecessor.map(String.init) ?? "NULL"),\(dailyPredecessor.map(String.init) ?? "NULL"),0,randomblob(32))"
    )
}

private func insertCorrectionInput(_ database: OpaquePointer, algorithm: Int, byte: UInt8) throws {
    try correctionExecute(
        database,
        "INSERT INTO historical_correction_input(algorithm_version,ranking_policy_version,input_format_version,input_sha256,canonical_input) VALUES(\(algorithm),1,1,\(hexBlob(byte, count: 32)),\(hexBlob(byte, count: 8)))"
    )
}

private func correctionWorkSQL(
    workID: Int,
    requestByte: UInt8,
    predecessorCorrectionID: Int?,
    algorithm: Int,
    expectedByte: UInt8
) -> String {
    "INSERT INTO historical_projection_correction_work(work_id,request_id,request_format_version,canonical_request_sha256,root_projection_id,predecessor_correcting_projection_id,expected_predecessor_sha256,algorithm_version,ranking_policy_version,correction_input_format_version,correction_input_sha256,created_at_ms) VALUES(\(workID),\(hexBlob(requestByte, count: 16)),1,\(hexBlob(requestByte, count: 32)),1,\(predecessorCorrectionID.map(String.init) ?? "NULL"),\(hexBlob(expectedByte, count: 32)),\(algorithm),1,1,\(hexBlob(UInt8(0x1f + algorithm), count: 32)),7200200)"
}

private func insertCorrectionWork(
    _ database: OpaquePointer,
    workID: Int,
    predecessorCorrectionID: Int?,
    algorithm: Int,
    expectedByte: UInt8
) throws {
    try correctionExecute(
        database,
        correctionWorkSQL(
            workID: workID,
            requestByte: UInt8(0x40 + workID),
            predecessorCorrectionID: predecessorCorrectionID,
            algorithm: algorithm,
            expectedByte: expectedByte
        )
    )
}

private func insertCorrectingProjection(
    _ database: OpaquePointer,
    projectionID: Int,
    workID: Int,
    resultByte: UInt8,
    findingCount: Int,
    rankedPositiveCount: Int = 0,
    reasonCount: Int = 0
) throws {
    try correctionExecute(
        database,
        "INSERT INTO historical_correcting_projection(correcting_projection_id,work_id,result_format_version,canonical_result_sha256,finding_count,ranked_positive_count,reason_count,truncated_positive_count,committed_at_ms,expires_at_ms) VALUES(\(projectionID),\(workID),1,\(hexBlob(resultByte, count: 32)),\(findingCount),\(rankedPositiveCount),\(reasonCount),0,7200200,2599200000)"
    )
}

private func hexBlob(_ byte: UInt8, count: Int) -> String {
    "X'\(String(repeating: String(format: "%02x", byte), count: count))'"
}

private func correctionExpectRejected(_ database: OpaquePointer, _ sql: String) throws {
    do {
        try correctionExecute(database, sql)
        Issue.record("Expected SQLite to reject the direct-SQL payload")
    } catch is CorrectionPhysicalDesignTestError {
        return
    }
}

private func correctionExecute(_ database: OpaquePointer, _ sql: String) throws {
    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &message)
    defer { sqlite3_free(message) }
    guard result == SQLITE_OK else {
        throw CorrectionPhysicalDesignTestError.sqlite(
            message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
        )
    }
}

private func correctionSchemaObjects(_ database: OpaquePointer) throws -> Set<String> {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT name FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'", -1, &statement, nil) == SQLITE_OK,
          let statement else { throw CorrectionPhysicalDesignTestError.sqlite("prepare schema") }
    defer { sqlite3_finalize(statement) }
    var values = Set<String>()
    while sqlite3_step(statement) == SQLITE_ROW {
        values.insert(String(cString: sqlite3_column_text(statement, 0)))
    }
    return values
}

private func correctionScalarText(_ database: OpaquePointer, _ sql: String) throws -> String {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement,
          sqlite3_step(statement) == SQLITE_ROW,
          let value = sqlite3_column_text(statement, 0) else {
        throw CorrectionPhysicalDesignTestError.sqlite("missing text")
    }
    defer { sqlite3_finalize(statement) }
    return String(cString: value)
}

private func correctionScalarInt(_ database: OpaquePointer, _ sql: String) throws -> Int {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement,
          sqlite3_step(statement) == SQLITE_ROW else {
        throw CorrectionPhysicalDesignTestError.sqlite("missing integer")
    }
    defer { sqlite3_finalize(statement) }
    return Int(sqlite3_column_int64(statement, 0))
}

private func correctionForeignKeyViolationCount(_ database: OpaquePointer) throws -> Int {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA foreign_key_check", -1, &statement, nil) == SQLITE_OK,
          let statement else { throw CorrectionPhysicalDesignTestError.sqlite("foreign key check") }
    defer { sqlite3_finalize(statement) }
    var count = 0
    while sqlite3_step(statement) == SQLITE_ROW { count += 1 }
    return count
}

private enum CorrectionPhysicalDesignTestError: Error {
    case sqlite(String)
}
