import Foundation
import SQLite3
import Testing
@_spi(Benchmark) @testable import SpaceTracePersistence

@Suite("SQLite v11 historical finding physical design", .serialized)
struct SQLiteHistoricalFindingPhysicalDesignTests {
    @Test("The provisional schema creates the complete named object set")
    func createsExactNamedObjects() throws {
        try withDatabase { database in
            try SQLiteHistoricalFindingSchema.installPrototype(on: database)

            let names = try schemaObjects(database)
            #expect(SQLiteHistoricalFindingSchema.prototypeObjectNames == expectedPrototypeObjectNames)
            for expected in expectedPrototypeObjectNames {
                #expect(names.contains(expected), "Missing schema object: \(expected)")
            }
            #expect(try scalarText(database, "PRAGMA integrity_check") == "ok")
            #expect(try scalarInt(database, "PRAGMA foreign_key_check") == 0)
        }
    }

    @Test("The benchmark SPI exposes an operation and result, never SQL or a handle")
    func keepsPrototypeSurfaceNarrow() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/SpaceTracePersistence/SQLiteHistoricalFindingSchema.swift"
            )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("public static func runPrototype("))
        #expect(source.contains("public struct SQLiteHistoricalPrototypeResult"))
        #expect(source.contains("public static func installPrototype") == false)
        #expect(source.contains("public let database") == false)
        #expect(source.contains("public let schemaSQL") == false)
    }

    @Test("The narrow prototype operation retains an exact 25-day window")
    func runsSmallPrototypeThroughPublicOperation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpaceTrace-v11-small-prototype-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("SpaceTrace.sqlite")
        let repository = try SQLiteEventJournalRepository(databaseURL: databaseURL)
        try await repository.close()

        let result = try SQLiteHistoricalFindingSchema.runPrototype(
            databaseURL: databaseURL,
            directorySamples: 250,
            scenario: .noChange
        )

        #expect(result.retainedV11Nodes == 250)
        #expect(result.removedV11Nodes == 50)
        #expect(result.retainedLegacyRows == 0)
        #expect(result.integrityCheck == "ok")
        #expect(result.foreignKeyViolationCount == 0)
        #expect(result.secureDeleteEnabled)
        #expect(result.queryPlans.isEmpty == false)
        #expect(result.queryPlans.joined(separator: " ").contains("historical_metric_endpoint_frame"))
        #expect(result.objectSizes.contains { $0.name == "historical_node_parent" && $0.bytes > 0 })
    }

    @Test(
        "Every prototype scenario closes on a small deterministic workload",
        arguments: SQLiteHistoricalPrototypeScenario.allCases.filter { $0 != .noChange }
    )
    func runsEveryPrototypeScenario(
        scenario: SQLiteHistoricalPrototypeScenario
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpaceTrace-v11-scenario-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("SpaceTrace.sqlite")
        let repository = try SQLiteEventJournalRepository(databaseURL: databaseURL)
        try await repository.close()

        let result = try SQLiteHistoricalFindingSchema.runPrototype(
            databaseURL: databaseURL,
            directorySamples: 2_500,
            scenario: scenario
        )

        let expectedV11 = scenario == .legacyOverlap ? 1_250 : 2_500
        #expect(result.retainedV11Nodes == expectedV11)
        #expect(result.removedV11Nodes == expectedV11 / 5)
        #expect(result.retainedLegacyRows == (scenario == .legacyOverlap ? 1_250 : 0))
        #expect((result.findingCount > 0) == (scenario == .twoPercentChurn))
        #expect(result.integrityCheck == "ok")
        #expect(result.foreignKeyViolationCount == 0)
    }

    @Test("Opaque byte identities preserve normalization and case distinctions")
    func preservesByteDistinctIdentities() throws {
        try withDatabase { database in
            try SQLiteHistoricalFindingSchema.installPrototype(on: database)
            let composed = Data("scope-é".utf8)
            let decomposed = Data("scope-e\u{301}".utf8)
            let uppercase = Data("SCOPE-é".utf8)
            for (key, value) in [(1, composed), (2, decomposed), (3, uppercase)] {
                try execute(
                    database,
                    "INSERT INTO historical_scope(scope_key,scope_id) VALUES(?,?)",
                    bindings: [.integer(Int64(key)), .blob(value)]
                )
            }
            #expect(try scalarInt(database, "SELECT count(*) FROM historical_scope") == 3)
        }
    }

    @Test("BLOB columns and bounded integer codes fail closed")
    func rejectsWrongStorageClassesAndCodes() throws {
        try withDatabase { database in
            try SQLiteHistoricalFindingSchema.installPrototype(on: database)
            #expect(throws: SQLitePhysicalDesignTestError.self) {
                try execute(database, "INSERT INTO historical_scope(scope_key,scope_id) VALUES(1,'text')")
            }
            try insertScope(database)
            for invalidBasis in [0, 3] {
                #expect(throws: SQLitePhysicalDesignTestError.self) {
                    try execute(
                        database,
                        "INSERT INTO historical_subject(subject_key,scope_key,identity_basis,subject_id) VALUES(?,?,?,?)",
                        bindings: [.integer(1), .integer(1), .integer(Int64(invalidBasis)), .blob(Data("subject".utf8))]
                    )
                }
            }
            try execute(database, "DELETE FROM historical_scope")
            for invalidReason in [0, 7] {
                try insertMinimalBatch(database)
                #expect(throws: SQLitePhysicalDesignTestError.self) {
                    try execute(
                        database,
                        "INSERT INTO historical_metric_endpoint(node_id,metric,frame_id,state_kind,bytes,measurement_coverage,unknown_reason_code) VALUES(1,1,1,3,NULL,NULL,?)",
                        bindings: [.integer(Int64(invalidReason))]
                    )
                }
                try execute(database, "DELETE FROM historical_endpoint_stable_identity")
                try execute(database, "DELETE FROM historical_observation_node")
                try execute(database, "DELETE FROM historical_observation_frame")
                try execute(database, "DELETE FROM historical_observation_batch")
                try execute(database, "DELETE FROM scan_run")
                try execute(database, "DELETE FROM historical_location")
                try execute(database, "DELETE FROM historical_subject")
                try execute(database, "DELETE FROM historical_scope")
                try execute(database, "DELETE FROM frozen_attribution_decision")
            }
        }
    }

    @Test("Every released integer discriminator rejects out-of-range values")
    func rejectsOutOfRangeDiscriminators() throws {
        try withDatabase { database in
            try SQLiteHistoricalFindingSchema.installPrototype(on: database)
            for days in [-1, 31] {
                try expectRejected(database, "UPDATE historical_retention_policy SET path_history_days=\(days) WHERE singleton=1")
            }
            for kind in [0, 4] {
                try expectRejected(
                    database,
                    "INSERT INTO frozen_attribution_decision(decision_id,format_version,canonical_payload,canonical_sha256,catalog_version,decision_kind,category_code,confidence_code,rule_id,rule_version,evidence_code) VALUES(\(kind + 10),1,X'01',zeroblob(32),1,\(kind),NULL,NULL,NULL,NULL,NULL)"
                )
            }
            for category in [0, 9] {
                try expectRejected(
                    database,
                    "INSERT INTO frozen_attribution_decision(decision_id,format_version,canonical_payload,canonical_sha256,catalog_version,decision_kind,category_code,confidence_code,rule_id,rule_version,evidence_code) VALUES(\(category + 20),1,X'01',randomblob(32),1,1,\(category),1,X'72',1,X'65')"
                )
            }
            for confidence in [0, 4] {
                try expectRejected(
                    database,
                    "INSERT INTO frozen_attribution_decision(decision_id,format_version,canonical_payload,canonical_sha256,catalog_version,decision_kind,category_code,confidence_code,rule_id,rule_version,evidence_code) VALUES(\(confidence + 40),1,X'01',randomblob(32),1,1,1,\(confidence),X'72',1,X'65')"
                )
            }
            for reason in [0, 4] {
                try expectRejected(
                    database,
                    "INSERT INTO historical_path_free_gap(reason_code,first_recorded_at_ms,last_recorded_at_ms,occurrence_count) VALUES(\(reason),0,0,1)"
                )
            }

            try insertMinimalBatch(database)
            for metric in [0, 3] {
                try expectRejected(database, "INSERT INTO historical_observation_frame(frame_id,batch_id,metric) VALUES(\(metric + 10),1,\(metric))")
            }
            for coverage in [0, 4] {
                try expectRejected(database, "INSERT INTO historical_observation_node(node_id,batch_id,subject_key,location_key,parent_node_id,observed_at_ms,direct_children_coverage,classification_decision_id) VALUES(\(coverage + 10),1,2,1,1,100,\(coverage),NULL)")
            }
            for state in [0, 4] {
                try expectRejected(database, "INSERT INTO historical_metric_endpoint(node_id,metric,frame_id,state_kind,bytes,measurement_coverage,unknown_reason_code) VALUES(1,1,1,\(state),NULL,NULL,NULL)")
            }
            for coverage in [0, 3] {
                try expectRejected(database, "INSERT INTO historical_metric_endpoint(node_id,metric,frame_id,state_kind,bytes,measurement_coverage,unknown_reason_code) VALUES(1,1,1,1,100,\(coverage),NULL)")
            }
            for reason in [0, 7] {
                try expectRejected(database, "INSERT INTO historical_metric_endpoint(node_id,metric,frame_id,state_kind,bytes,measurement_coverage,unknown_reason_code) VALUES(1,1,1,3,NULL,NULL,\(reason))")
            }
            for guardKind in [0, 3] {
                try expectRejected(database, "INSERT INTO historical_endpoint_stable_identity(node_id,guard_kind,generation_token_utf8,birth_seconds,birth_nanoseconds,node_kind,link_status) VALUES(1,\(guardKind),X'01',NULL,NULL,1,1)")
            }
            for linkStatus in [0, 4] {
                try expectRejected(database, "INSERT INTO historical_endpoint_stable_identity(node_id,guard_kind,generation_token_utf8,birth_seconds,birth_nanoseconds,node_kind,link_status) VALUES(1,1,X'01',NULL,NULL,1,\(linkStatus))")
            }
            for nanoseconds in [-1, 1_000_000_000] {
                try expectRejected(database, "INSERT INTO historical_endpoint_stable_identity(node_id,guard_kind,generation_token_utf8,birth_seconds,birth_nanoseconds,node_kind,link_status) VALUES(1,2,NULL,1,\(nanoseconds),1,1)")
            }
        }
    }

    @Test("Every byte field enforces storage class and released size limits")
    func enforcesByteFieldBudgets() throws {
        try withDatabase { database in
            try SQLiteHistoricalFindingSchema.installPrototype(on: database)
            try expectRejected(database, "INSERT INTO historical_store_identity VALUES(1,1,zeroblob(16))")
            try expectRejected(database, "INSERT INTO historical_store_identity VALUES(1,1,zeroblob(15))")
            try expectRejected(database, "INSERT INTO historical_store_identity VALUES(1,1,zeroblob(17))")
            try expectRejected(database, "INSERT INTO historical_scope(scope_key,scope_id) VALUES(1,zeroblob(0))")
            try expectRejected(database, "INSERT INTO historical_scope(scope_key,scope_id) VALUES(1,zeroblob(4097))")
            try insertScope(database)
            for pathSQL in ["X''", "X'6e6f742d726f6f74'", "X'2f00'", "zeroblob(4097)"] {
                try expectRejected(
                    database,
                    "INSERT INTO historical_location(location_key,scope_key,path_semantics_version,location_id,path_utf8,display_name_utf8) VALUES(1,1,1,X'6c',\(pathSQL),X'64')"
                )
            }
            for displaySQL in ["X''", "X'2f'", "X'00'", "zeroblob(1025)"] {
                try expectRejected(
                    database,
                    "INSERT INTO historical_location(location_key,scope_key,path_semantics_version,location_id,path_utf8,display_name_utf8) VALUES(1,1,1,X'6c',X'2f',\(displaySQL))"
                )
            }
            try expectRejected(
                database,
                "INSERT INTO frozen_attribution_decision(decision_id,format_version,canonical_payload,canonical_sha256,catalog_version,decision_kind,category_code,confidence_code,rule_id,rule_version,evidence_code) VALUES(1,1,zeroblob(0),zeroblob(32),1,2,NULL,NULL,NULL,NULL,NULL)"
            )
            try expectRejected(
                database,
                "INSERT INTO frozen_attribution_decision(decision_id,format_version,canonical_payload,canonical_sha256,catalog_version,decision_kind,category_code,confidence_code,rule_id,rule_version,evidence_code) VALUES(1,1,zeroblob(65537),zeroblob(32),1,2,NULL,NULL,NULL,NULL,NULL)"
            )
        }
    }

    @Test("A canonical digest collision never accepts different attribution bytes")
    func rejectsHashOnlyDictionaryCollision() throws {
        try withDatabase { database in
            try SQLiteHistoricalFindingSchema.installPrototype(on: database)
            try execute(database, "INSERT INTO frozen_attribution_decision(decision_id,format_version,canonical_payload,canonical_sha256,catalog_version,decision_kind,category_code,confidence_code,rule_id,rule_version,evidence_code) VALUES(1,1,X'01',zeroblob(32),1,2,NULL,NULL,NULL,NULL,NULL)")
            try expectRejected(database, "INSERT INTO frozen_attribution_decision(decision_id,format_version,canonical_payload,canonical_sha256,catalog_version,decision_kind,category_code,confidence_code,rule_id,rule_version,evidence_code) VALUES(2,1,X'02',zeroblob(32),1,2,NULL,NULL,NULL,NULL,NULL)")
        }
    }

    @Test("Commit markers require a complete logical and allocated sibling set")
    func rejectsMissingOrContradictoryMetricSibling() throws {
        try withDatabase { database in
            try SQLiteHistoricalFindingSchema.installPrototype(on: database)
            try insertMinimalBatch(database)
            try insertPresentEndpoint(database, nodeID: 1, metric: 1, frameID: 1, bytes: 100)
            #expect(throws: SQLitePhysicalDesignTestError.self) {
                try insertCommit(database, sequence: 1, frameID: 1, metric: 1)
            }

            #expect(throws: SQLitePhysicalDesignTestError.self) {
                try execute(
                    database,
                    "INSERT INTO historical_metric_endpoint(node_id,metric,frame_id,state_kind,bytes,measurement_coverage,unknown_reason_code) VALUES(1,2,2,1,101,2,NULL)"
                )
            }
        }
    }

    @Test("Frame authority rejects missing stable evidence and raw path aliases")
    func rejectsStableAndRawIdentityContradictions() throws {
        try withDatabase { database in
            try SQLiteHistoricalFindingSchema.installPrototype(on: database)
            try insertMinimalBatch(database)
            try execute(database, "DELETE FROM historical_endpoint_stable_identity WHERE node_id=1")
            try insertPresentEndpoint(database, nodeID: 1, metric: 1, frameID: 1, bytes: 100)
            try insertPresentEndpoint(database, nodeID: 1, metric: 2, frameID: 2, bytes: 100)
            try expectRejected(
                database,
                "INSERT INTO historical_observation_frame_commit(sequence,frame_id,root_node_id,root_metric,endpoint_count,committed_at_ms,retention_anchor_ms,expires_at_ms) VALUES(1,1,1,1,1,100,100,2592000100)"
            )
        }

        try withDatabase { database in
            try SQLiteHistoricalFindingSchema.installPrototype(on: database)
            try insertMinimalBatch(database)
            try execute(database, "INSERT INTO historical_location(location_key,scope_key,path_semantics_version,location_id,path_utf8,display_name_utf8) VALUES(2,1,1,X'6c32',X'2f526f6f74',X'4368696c64')")
            try execute(database, "INSERT INTO historical_observation_node(node_id,batch_id,subject_key,location_key,parent_node_id,observed_at_ms,direct_children_coverage,classification_decision_id) VALUES(2,1,2,2,1,100,1,1)")
            try execute(database, "INSERT INTO historical_endpoint_stable_identity(node_id,guard_kind,generation_token_utf8,birth_seconds,birth_nanoseconds,node_kind,link_status) VALUES(2,1,X'67656e65726174696f6e32',NULL,NULL,1,1)")
            try insertPresentEndpoint(database, nodeID: 1, metric: 1, frameID: 1, bytes: 100)
            try insertPresentEndpoint(database, nodeID: 1, metric: 2, frameID: 2, bytes: 100)
            try insertPresentEndpoint(database, nodeID: 2, metric: 1, frameID: 1, bytes: 50)
            try insertPresentEndpoint(database, nodeID: 2, metric: 2, frameID: 2, bytes: 50)
            try expectRejected(
                database,
                "INSERT INTO historical_observation_frame_commit(sequence,frame_id,root_node_id,root_metric,endpoint_count,committed_at_ms,retention_anchor_ms,expires_at_ms) VALUES(1,1,1,1,2,100,100,2592000100)"
            )
        }
    }

    @Test("Absence needs a complete direct parent and one authoritative root")
    func rejectsIncompleteAbsenceAndMultipleRoots() throws {
        try withDatabase { database in
            try SQLiteHistoricalFindingSchema.installPrototype(on: database)
            try insertMinimalBatch(database, rootDirectCoverage: 2)
            try insertChildNode(database, parentNodeID: 1, locationPath: "/Child")
            try insertPresentEndpoint(database, nodeID: 1, metric: 1, frameID: 1, bytes: 100)
            try insertPresentEndpoint(database, nodeID: 1, metric: 2, frameID: 2, bytes: 100)
            try insertAbsentEndpoint(database, nodeID: 2, metric: 1, frameID: 1)
            try insertAbsentEndpoint(database, nodeID: 2, metric: 2, frameID: 2)
            try expectRejected(
                database,
                "INSERT INTO historical_observation_frame_commit(sequence,frame_id,root_node_id,root_metric,endpoint_count,committed_at_ms,retention_anchor_ms,expires_at_ms) VALUES(1,1,1,1,2,100,100,2592000100)"
            )
        }

        try withDatabase { database in
            try SQLiteHistoricalFindingSchema.installPrototype(on: database)
            try insertMinimalBatch(database)
            try insertChildNode(database, parentNodeID: nil, locationPath: "/Second")
            try insertPresentEndpoint(database, nodeID: 1, metric: 1, frameID: 1, bytes: 100)
            try insertPresentEndpoint(database, nodeID: 1, metric: 2, frameID: 2, bytes: 100)
            try insertPresentEndpoint(database, nodeID: 2, metric: 1, frameID: 1, bytes: 50)
            try insertPresentEndpoint(database, nodeID: 2, metric: 2, frameID: 2, bytes: 50)
            try expectRejected(
                database,
                "INSERT INTO historical_observation_frame_commit(sequence,frame_id,root_node_id,root_metric,endpoint_count,committed_at_ms,retention_anchor_ms,expires_at_ms) VALUES(1,1,1,1,2,100,100,2592000100)"
            )
        }
    }

    @Test("Committed frames cannot be extended with late nodes")
    func rejectsLateFrameMutation() throws {
        try withDatabase { database in
            try SQLiteHistoricalFindingSchema.installPrototype(on: database)
            try insertTwoCommittedBatches(database)
            try execute(database, "INSERT INTO historical_subject(subject_key,scope_key,identity_basis,subject_id) VALUES(3,1,2,X'6c617465')")
            try execute(database, "INSERT INTO historical_location(location_key,scope_key,path_semantics_version,location_id,path_utf8,display_name_utf8) VALUES(3,1,1,X'6c617465',X'2f4c617465',X'4c617465')")
            try expectRejected(database, "INSERT INTO historical_observation_node(node_id,batch_id,subject_key,location_key,parent_node_id,observed_at_ms,direct_children_coverage,classification_decision_id) VALUES(3,1,3,3,1,100,1,1)")
        }
    }

    @Test("Commit markers enforce one root and exact root subject")
    func rejectsInvalidRootShape() throws {
        try withDatabase { database in
            try SQLiteHistoricalFindingSchema.installPrototype(on: database)
            try insertMinimalBatch(database, rootSubjectKey: 2)
            try insertPresentEndpoint(database, nodeID: 1, metric: 1, frameID: 1, bytes: 100)
            try insertPresentEndpoint(database, nodeID: 1, metric: 2, frameID: 2, bytes: 100)
            #expect(throws: SQLitePhysicalDesignTestError.self) {
                try insertCommit(database, sequence: 1, frameID: 1, metric: 1)
            }
        }
    }

    @Test("Main and history-disabled receipts cannot reuse a run UUID")
    func rejectsReceiptIdentityReuse() throws {
        try withDatabase { database in
            try SQLiteHistoricalFindingSchema.installPrototype(on: database)
            try execute(
                database,
                "INSERT INTO historical_disabled_calibration_receipt(receipt_id,request_format_version,canonical_request_sha256,committed_at_ms,expires_at_ms) VALUES(?,1,?,100,604800100)",
                bindings: [.blob(uuidBytes), .blob(Data(repeating: 1, count: 32))]
            )
            try insertMinimalBatch(database)
            #expect(throws: SQLitePhysicalDesignTestError.self) {
                try execute(
                    database,
                    "INSERT INTO historical_calibration_receipt(scan_run_id,request_format_version,canonical_request_sha256,outcome,logical_sequence,allocated_sequence,committed_at_ms,retention_anchor_ms,expires_at_ms) VALUES('00112233-4455-6677-8899-aabbccddeeff',1,?,2,NULL,NULL,100,100,604800100)",
                    bindings: [.blob(Data(repeating: 2, count: 32))]
                )
            }
        }
    }

    @Test("Wrong-frame findings cannot enter a projection")
    func rejectsWrongWorkFinding() throws {
        try withDatabase { database in
            try SQLiteHistoricalFindingSchema.installPrototype(on: database)
            try insertTwoCommittedBatches(database)
            try execute(database, "INSERT INTO historical_projection_work(work_id,baseline_sequence,comparison_sequence,algorithm_version,ranking_policy_version,positive_limit,created_at_ms) VALUES(1,1,3,1,1,10,100)")
            try execute(database, "INSERT INTO historical_finding_projection(projection_id,work_id,format_version,canonical_result_sha256,truncated_positive_count,committed_at_ms) VALUES(1,1,1,?,0,100)", bindings: [.blob(Data(repeating: 3, count: 32))])
            #expect(throws: SQLitePhysicalDesignTestError.self) {
                try execute(
                    database,
                    "INSERT INTO historical_finding(projection_id,ordinal,finding_key_sha256,draft_sha256,baseline_node_id,baseline_metric,comparison_node_id,comparison_metric,kind,inclusive_delta_bytes,ranking_contribution_bytes,movement_ancestor_finding_id,expires_at_ms) VALUES(1,0,?,?,2,1,1,1,4,10,10,NULL,2592000100)",
                    bindings: [.blob(Data(repeating: 4, count: 32)), .blob(Data(repeating: 5, count: 32))]
                )
            }
        }
    }

    @Test("Finding shape, rank and reason-category pairs fail closed")
    func validatesFindingProjectionShape() throws {
        try withDatabase { database in
            try SQLiteHistoricalFindingSchema.installPrototype(on: database)
            try insertTwoCommittedBatches(database)
            try execute(database, "INSERT INTO historical_projection_work(work_id,baseline_sequence,comparison_sequence,algorithm_version,ranking_policy_version,positive_limit,created_at_ms) VALUES(1,1,3,1,1,10,100)")
            try execute(database, "INSERT INTO historical_finding_projection(projection_id,work_id,format_version,canonical_result_sha256,truncated_positive_count,committed_at_ms) VALUES(1,1,1,?,0,100)", bindings: [.blob(Data(repeating: 1, count: 32))])
            try execute(
                database,
                "INSERT INTO historical_finding(projection_id,ordinal,finding_key_sha256,draft_sha256,baseline_node_id,baseline_metric,comparison_node_id,comparison_metric,kind,inclusive_delta_bytes,ranking_contribution_bytes,movement_ancestor_finding_id,expires_at_ms) VALUES(1,0,?,?,1,1,2,1,4,10,10,NULL,2592000100)",
                bindings: [.blob(Data(repeating: 2, count: 32)), .blob(Data(repeating: 3, count: 32))]
            )
            for kind in [0, 6] {
                try expectRejected(
                    database,
                    "INSERT INTO historical_finding(projection_id,ordinal,finding_key_sha256,draft_sha256,baseline_node_id,baseline_metric,comparison_node_id,comparison_metric,kind,inclusive_delta_bytes,ranking_contribution_bytes,movement_ancestor_finding_id,expires_at_ms) VALUES(1,\(kind + 10),randomblob(32),randomblob(32),1,1,2,1,\(kind),10,10,NULL,2592000100)"
                )
            }
            try expectRejected(
                database,
                "INSERT INTO historical_finding(projection_id,ordinal,finding_key_sha256,draft_sha256,baseline_node_id,baseline_metric,comparison_node_id,comparison_metric,kind,inclusive_delta_bytes,ranking_contribution_bytes,movement_ancestor_finding_id,expires_at_ms) VALUES(1,20,randomblob(32),randomblob(32),1,1,2,1,5,0,NULL,NULL,2592000100)"
            )
            try execute(database, "INSERT INTO historical_finding_positive_rank(projection_id,rank,finding_id) VALUES(1,1,1)")
            for pair in [(1, 31), (2, 30), (2, 35), (3, 34)] {
                try expectRejected(
                    database,
                    "INSERT INTO historical_finding_reason_count(projection_id,category,reason_code,count) VALUES(1,\(pair.0),\(pair.1),1)"
                )
            }
            try execute(database, "INSERT INTO historical_finding_reason_count(projection_id,category,reason_code,count) VALUES(1,1,1,1),(1,2,31,1),(1,3,35,1)")
        }
    }
}

private let uuidBytes = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])

private let expectedPrototypeObjectNames: Set<String> = [
    "historical_store_identity", "historical_scope", "historical_retention_policy",
    "historical_subject", "historical_location", "frozen_attribution_decision",
    "frozen_attribution_competitor", "historical_observation_batch",
    "historical_observation_frame", "historical_observation_node",
    "historical_metric_endpoint", "historical_endpoint_stable_identity",
    "historical_observation_frame_commit", "historical_calibration_receipt",
    "historical_disabled_calibration_receipt", "historical_observation_baseline_checkpoint",
    "historical_projection_work", "historical_finding_projection",
    "historical_projection_checkpoint", "historical_finding",
    "historical_finding_positive_rank", "historical_finding_reason_count",
    "historical_finding_retraction", "historical_path_free_gap",
    "historical_batch_scope", "historical_batch_root_subject", "historical_node_subject",
    "historical_node_location", "historical_node_parent",
    "historical_node_classification_decision", "historical_metric_endpoint_frame",
    "historical_frame_commit_root_endpoint", "node_current_last_scan_run",
    "historical_projection_work_baseline", "historical_finding_baseline_endpoint",
    "historical_finding_comparison_endpoint", "historical_finding_movement_ancestor",
    "historical_node_validate_insert", "historical_metric_endpoint_validate_insert",
    "historical_stable_identity_validate_insert", "historical_frame_commit_validate",
    "historical_calibration_receipt_validate", "historical_disabled_calibration_receipt_validate",
    "historical_baseline_validate_series", "historical_work_validate_pair",
    "historical_finding_validate_insert", "historical_rank_validate_projection",
    "historical_retraction_validate_target", "historical_store_identity_immutable_update",
    "historical_scope_immutable_update", "historical_subject_immutable_update",
    "historical_location_immutable_update", "historical_attribution_decision_immutable_update",
    "historical_attribution_competitor_immutable_update", "historical_batch_immutable_update",
    "historical_frame_immutable_update", "historical_node_immutable_update",
    "historical_metric_endpoint_immutable_update", "historical_stable_identity_immutable_update",
    "historical_frame_commit_immutable_update", "historical_calibration_receipt_immutable_update",
    "historical_disabled_calibration_receipt_immutable_update",
    "historical_baseline_checkpoint_immutable_update",
    "historical_projection_work_immutable_update", "historical_projection_immutable_update",
    "historical_projection_checkpoint_immutable_update", "historical_finding_immutable_update",
    "historical_rank_immutable_update", "historical_reason_count_immutable_update",
    "historical_retraction_immutable_update",
]

private func withDatabase(_ body: (OpaquePointer) throws -> Void) throws {
    var database: OpaquePointer?
    guard sqlite3_open(":memory:", &database) == SQLITE_OK, let database else {
        throw SQLitePhysicalDesignTestError.sqlite("open")
    }
    defer { sqlite3_close(database) }
    try execute(database, "PRAGMA foreign_keys=ON")
    try createLegacyParents(database)
    try body(database)
}

private func createLegacyParents(_ database: OpaquePointer) throws {
    try execute(database, "CREATE TABLE scan_run(id TEXT PRIMARY KEY, state TEXT NOT NULL DEFAULT 'running')")
    try execute(database, "CREATE TABLE node_current(last_scan_run_id TEXT REFERENCES scan_run(id))")
}

private func insertScope(_ database: OpaquePointer) throws {
    try execute(database, "INSERT INTO historical_scope(scope_key,scope_id) VALUES(1,?)", bindings: [.blob(Data("scope".utf8))])
}

private func insertMinimalBatch(
    _ database: OpaquePointer,
    rootSubjectKey: Int = 1,
    rootDirectCoverage: Int = 1
) throws {
    try insertScope(database)
    try execute(database, "INSERT INTO historical_subject(subject_key,scope_key,identity_basis,subject_id) VALUES(1,1,1,?), (2,1,1,?)", bindings: [.blob(Data("root".utf8)), .blob(Data("other".utf8))])
    try execute(database, "INSERT INTO historical_location(location_key,scope_key,path_semantics_version,location_id,path_utf8,display_name_utf8) VALUES(1,1,1,?,?,?)", bindings: [.blob(Data("location".utf8)), .blob(Data("/Root".utf8)), .blob(Data("Root".utf8))])
    try execute(database, "INSERT INTO scan_run(id) VALUES('00112233-4455-6677-8899-aabbccddeeff')")
    try execute(database, "INSERT INTO historical_observation_batch(batch_id,scan_run_id,stream_id_utf8,scope_key,root_subject_key,volume_id,mount_generation_id,coverage_epoch_id,path_semantics_version,measurement_semantics_version,created_at_ms) VALUES(1,'00112233-4455-6677-8899-aabbccddeeff',?,1,?,?,?,?,1,1,100)", bindings: [.blob(Data("stream".utf8)), .integer(Int64(rootSubjectKey)), .blob(Data("volume".utf8)), .blob(Data("mount".utf8)), .blob(Data("epoch".utf8))])
    try execute(database, "INSERT INTO historical_observation_frame(frame_id,batch_id,metric) VALUES(1,1,1),(2,1,2)")
    try execute(database, "INSERT INTO frozen_attribution_decision(decision_id,format_version,canonical_payload,canonical_sha256,catalog_version,decision_kind,category_code,confidence_code,rule_id,rule_version,evidence_code) VALUES(1,1,?, ?,1,2,NULL,NULL,NULL,NULL,NULL)", bindings: [.blob(Data("decision".utf8)), .blob(Data(repeating: 9, count: 32))])
    try execute(database, "INSERT INTO historical_observation_node(node_id,batch_id,subject_key,location_key,parent_node_id,observed_at_ms,direct_children_coverage,classification_decision_id) VALUES(1,1,1,1,NULL,100,\(rootDirectCoverage),1)")
    try execute(database, "INSERT INTO historical_endpoint_stable_identity(node_id,guard_kind,generation_token_utf8,birth_seconds,birth_nanoseconds,node_kind,link_status) VALUES(1,1,?,NULL,NULL,1,1)", bindings: [.blob(Data("generation".utf8))])
}

private func insertChildNode(
    _ database: OpaquePointer,
    parentNodeID: Int?,
    locationPath: String
) throws {
    try execute(
        database,
        "INSERT INTO historical_location(location_key,scope_key,path_semantics_version,location_id,path_utf8,display_name_utf8) VALUES(2,1,1,?,?,?)",
        bindings: [.blob(Data("location-2".utf8)), .blob(Data(locationPath.utf8)), .blob(Data("Child".utf8))]
    )
    let parent = parentNodeID.map(String.init) ?? "NULL"
    try execute(database, "INSERT INTO historical_observation_node(node_id,batch_id,subject_key,location_key,parent_node_id,observed_at_ms,direct_children_coverage,classification_decision_id) VALUES(2,1,2,2,\(parent),100,3,NULL)")
    try execute(database, "INSERT INTO historical_endpoint_stable_identity(node_id,guard_kind,generation_token_utf8,birth_seconds,birth_nanoseconds,node_kind,link_status) VALUES(2,1,?,NULL,NULL,1,1)", bindings: [.blob(Data("generation-2".utf8))])
}

private func insertAbsentEndpoint(
    _ database: OpaquePointer,
    nodeID: Int,
    metric: Int,
    frameID: Int
) throws {
    try execute(database, "INSERT INTO historical_metric_endpoint(node_id,metric,frame_id,state_kind,bytes,measurement_coverage,unknown_reason_code) VALUES(?,?,?,2,NULL,NULL,NULL)", bindings: [.integer(Int64(nodeID)), .integer(Int64(metric)), .integer(Int64(frameID))])
}

private func insertPresentEndpoint(_ database: OpaquePointer, nodeID: Int, metric: Int, frameID: Int, bytes: Int) throws {
    try execute(database, "INSERT INTO historical_metric_endpoint(node_id,metric,frame_id,state_kind,bytes,measurement_coverage,unknown_reason_code) VALUES(?,?,?,1,?,1,NULL)", bindings: [.integer(Int64(nodeID)), .integer(Int64(metric)), .integer(Int64(frameID)), .integer(Int64(bytes))])
}

private func insertCommit(_ database: OpaquePointer, sequence: Int, frameID: Int, metric: Int) throws {
    try execute(database, "INSERT INTO historical_observation_frame_commit(sequence,frame_id,root_node_id,root_metric,endpoint_count,committed_at_ms,retention_anchor_ms,expires_at_ms) VALUES(?,?,1,?,1,100,100,2592000100)", bindings: [.integer(Int64(sequence)), .integer(Int64(frameID)), .integer(Int64(metric))])
}

private func insertTwoCommittedBatches(_ database: OpaquePointer) throws {
    try insertMinimalBatch(database)
    try insertPresentEndpoint(database, nodeID: 1, metric: 1, frameID: 1, bytes: 100)
    try insertPresentEndpoint(database, nodeID: 1, metric: 2, frameID: 2, bytes: 100)
    try insertCommit(database, sequence: 1, frameID: 1, metric: 1)
    try insertCommit(database, sequence: 2, frameID: 2, metric: 2)
    try execute(database, "INSERT INTO scan_run(id) VALUES('10112233-4455-6677-8899-aabbccddeeff')")
    try execute(database, "INSERT INTO historical_observation_batch(batch_id,scan_run_id,stream_id_utf8,scope_key,root_subject_key,volume_id,mount_generation_id,coverage_epoch_id,path_semantics_version,measurement_semantics_version,created_at_ms) SELECT 2,'10112233-4455-6677-8899-aabbccddeeff',stream_id_utf8,scope_key,root_subject_key,volume_id,mount_generation_id,coverage_epoch_id,path_semantics_version,measurement_semantics_version,200 FROM historical_observation_batch WHERE batch_id=1")
    try execute(database, "INSERT INTO historical_observation_frame(frame_id,batch_id,metric) VALUES(3,2,1),(4,2,2)")
    try execute(database, "INSERT INTO historical_observation_node(node_id,batch_id,subject_key,location_key,parent_node_id,observed_at_ms,direct_children_coverage,classification_decision_id) VALUES(2,2,1,1,NULL,200,1,1)")
    try execute(database, "INSERT INTO historical_endpoint_stable_identity(node_id,guard_kind,generation_token_utf8,birth_seconds,birth_nanoseconds,node_kind,link_status) VALUES(2,1,?,NULL,NULL,1,1)", bindings: [.blob(Data("generation".utf8))])
    try insertPresentEndpoint(database, nodeID: 2, metric: 1, frameID: 3, bytes: 110)
    try insertPresentEndpoint(database, nodeID: 2, metric: 2, frameID: 4, bytes: 110)
    try execute(database, "INSERT INTO historical_observation_frame_commit(sequence,frame_id,root_node_id,root_metric,endpoint_count,committed_at_ms,retention_anchor_ms,expires_at_ms) VALUES(3,3,2,1,1,200,200,2592000200),(4,4,2,2,1,200,200,2592000200)")
}

private enum SQLiteBinding {
    case integer(Int64)
    case blob(Data)
}

private func expectRejected(_ database: OpaquePointer, _ sql: String) throws {
    do {
        try execute(database, sql)
        Issue.record("Expected SQLite to reject the direct-SQL payload.")
    } catch is SQLitePhysicalDesignTestError {
        return
    }
}

private func execute(_ database: OpaquePointer, _ sql: String, bindings: [SQLiteBinding] = []) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw SQLitePhysicalDesignTestError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    for (index, binding) in bindings.enumerated() {
        switch binding {
        case let .integer(value): sqlite3_bind_int64(statement, Int32(index + 1), value)
        case let .blob(value):
            value.withUnsafeBytes { buffer in
                _ = sqlite3_bind_blob(statement, Int32(index + 1), buffer.baseAddress, Int32(value.count), sqliteTransient)
            }
        }
    }
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw SQLitePhysicalDesignTestError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
}

private func schemaObjects(_ database: OpaquePointer) throws -> Set<String> {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT name FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'", -1, &statement, nil) == SQLITE_OK, let statement else { throw SQLitePhysicalDesignTestError.sqlite("prepare schema") }
    defer { sqlite3_finalize(statement) }
    var values = Set<String>()
    while sqlite3_step(statement) == SQLITE_ROW { values.insert(String(cString: sqlite3_column_text(statement, 0))) }
    return values
}

private func scalarText(_ database: OpaquePointer, _ sql: String) throws -> String {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement, sqlite3_step(statement) == SQLITE_ROW else { throw SQLitePhysicalDesignTestError.sqlite("scalar text") }
    defer { sqlite3_finalize(statement) }
    return String(cString: sqlite3_column_text(statement, 0))
}

private func scalarInt(_ database: OpaquePointer, _ sql: String) throws -> Int {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SQLitePhysicalDesignTestError.sqlite("scalar int") }
    defer { sqlite3_finalize(statement) }
    if sql.hasPrefix("PRAGMA foreign_key_check") {
        var count = 0
        while sqlite3_step(statement) == SQLITE_ROW { count += 1 }
        return count
    }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw SQLitePhysicalDesignTestError.sqlite("missing scalar row")
    }
    return Int(sqlite3_column_int64(statement, 0))
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private enum SQLitePhysicalDesignTestError: Error { case sqlite(String) }
