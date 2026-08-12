import CryptoKit
import Foundation
import SpaceTraceApplication
import SpaceTraceDomain
import Testing
@testable import SpaceTraceApplication
@testable import SpaceTracePersistence

@Suite("SQLite historical finding retractions and effective queries", .serialized)
struct SQLiteHistoricalFindingRetractionTests {
    @Test("Only typed integrity failures authorize evidence invalidation")
    func authorizerCopiesStoredEvidenceAndRejectsRetractedRecords() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try retractionRepository(for: fixture)
        let projection = try await commitRetractionProjection(repository: repository)
        let stored = try #require(
            try await repository.historicalFindingAuditRecord(id: projection.findings[0].recordID)
        )
        let requestID = try HistoricalRetractionRequestID(bytes: Array(0..<16))

        let command = try HistoricalFindingIntegrityReconciliationAuthorizer
            .authorizeEvidenceInvalidation(
                requestID: requestID,
                failure: .projectionIntegrityViolation,
                storedAuditRecord: stored
            )
        #expect(command.requestID == requestID)
        #expect(command.findingID == stored.finding.recordID)
        #expect(command.expectedDraftSHA256 == stored.draftSHA256)

        _ = try await repository.commitEvidenceInvalidation(command)
        let retracted = try #require(
            try await repository.historicalFindingAuditRecord(id: stored.finding.recordID)
        )
        #expect(retracted.finding == stored.finding)
        #expect(retracted.draftSHA256 == stored.draftSHA256)
        #expect(retracted.retraction?.reason == .evidenceInvalidated)
        #expect(throws: HistoricalFindingPersistenceModelError.findingAlreadyRetracted) {
            _ = try HistoricalFindingIntegrityReconciliationAuthorizer
                .authorizeEvidenceInvalidation(
                    requestID: try HistoricalRetractionRequestID(bytes: Array(16..<32)),
                    failure: .ledgerIntegrityViolation,
                    storedAuditRecord: retracted
                )
        }
        try await repository.close()
    }

    @Test("Retraction commit survives response loss and conflicting retries fail closed")
    func responseLossIsIdempotentAndConflictsAreRejected() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        var repository = try retractionRepository(
            for: fixture,
            failurePoint: .afterHistoricalRetractionCommitBeforeReturningReceipt
        )
        let projection = try await commitRetractionProjection(repository: repository)
        let first = try #require(
            try await repository.historicalFindingAuditRecord(id: projection.findings[0].recordID)
        )
        let second = try #require(
            try await repository.historicalFindingAuditRecord(id: projection.findings[1].recordID)
        )
        let requestID = try HistoricalRetractionRequestID(bytes: Array(repeating: 0x31, count: 16))
        let command = try HistoricalFindingIntegrityReconciliationAuthorizer
            .authorizeEvidenceInvalidation(
                requestID: requestID,
                failure: .ledgerIntegrityViolation,
                storedAuditRecord: first
            )

        await #expect(throws: SQLiteEventJournalError.injectedFailure) {
            _ = try await repository.commitEvidenceInvalidation(command)
        }
        #expect(try fixture.count("historical_finding_retraction") == 1)
        let storedDigest = try #require(
            try fixture.rows(
                "SELECT lower(hex(canonical_request_sha256)) FROM historical_finding_retraction"
            ).first?.first
        )
        #expect(storedDigest == retractionDigestHex(command))
        try await repository.close()

        repository = try retractionRepository(for: fixture)
        let retry = try await repository.commitEvidenceInvalidation(command)
        guard case .alreadyCommitted(let receipt) = retry else {
            Issue.record("Expected exact response-loss retry to rehydrate the retraction.")
            return
        }
        #expect(receipt.findingID == first.finding.recordID)
        #expect(
            receipt.committedAt
                != (try ObservationInstant(millisecondsSince1970: 2_000_000_010_000))
        )

        let sameRequestDifferentTarget = try HistoricalFindingIntegrityReconciliationAuthorizer
            .authorizeEvidenceInvalidation(
                requestID: requestID,
                failure: .projectionIntegrityViolation,
                storedAuditRecord: second
            )
        await #expect(throws: SQLiteEventJournalError.historicalRetractionImmutableConflict) {
            _ = try await repository.commitEvidenceInvalidation(sameRequestDifferentTarget)
        }

        let differentRequestSameTarget = try HistoricalFindingIntegrityReconciliationAuthorizer
            .authorizeEvidenceInvalidation(
                requestID: try HistoricalRetractionRequestID(bytes: Array(repeating: 0x32, count: 16)),
                failure: .ledgerIntegrityViolation,
                storedAuditRecord: first
            )
        await #expect(throws: SQLiteEventJournalError.historicalRetractionImmutableConflict) {
            _ = try await repository.commitEvidenceInvalidation(differentRequestSameTarget)
        }
        #expect(try fixture.count("historical_finding_retraction") == 1)
        try await repository.close()
    }

    @Test("Failure before commit rolls back the retraction and preserves effective visibility")
    func preCommitFailureRollsBack() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try retractionRepository(
            for: fixture,
            failurePoint: .beforeHistoricalRetractionCommit
        )
        let projection = try await commitRetractionProjection(repository: repository)
        let stored = try #require(
            try await repository.historicalFindingAuditRecord(id: projection.findings[0].recordID)
        )
        let command = try HistoricalFindingIntegrityReconciliationAuthorizer
            .authorizeEvidenceInvalidation(
                requestID: try HistoricalRetractionRequestID(bytes: Array(repeating: 0x35, count: 16)),
                failure: .ledgerIntegrityViolation,
                storedAuditRecord: stored
            )

        await #expect(throws: SQLiteEventJournalError.injectedFailure) {
            _ = try await repository.commitEvidenceInvalidation(command)
        }
        #expect(try fixture.count("historical_finding_retraction") == 0)
        let effective = try await repository.effectiveHistoricalFindings(
            for: ScopeID("scope-fixture"),
            through: projection.comparisonSequence,
            limit: HistoricalFindingQueryLimit(1_000)
        )
        #expect(effective.contains(where: { $0.recordID == stored.finding.recordID }))
        try await repository.close()
    }

    @Test("SQLite revalidates unknown targets and stale evidence digests")
    func unknownAndStaleTargetsFailClosed() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try retractionRepository(for: fixture)
        let projection = try await commitRetractionProjection(repository: repository)
        let stored = try #require(
            try await repository.historicalFindingAuditRecord(id: projection.findings[0].recordID)
        )
        let unknownFinding = try EffectiveHistoricalFinding(
            recordID: HistoricalFindingRecordID(9_999),
            projectionID: stored.finding.projectionID,
            comparisonSequence: stored.finding.comparisonSequence,
            positiveRank: stored.finding.positiveRank,
            draft: stored.finding.draft
        )
        let unknownAudit = try HistoricalFindingAuditRecord(
            finding: unknownFinding,
            draftSHA256: stored.draftSHA256,
            retraction: nil
        )
        let unknown = try HistoricalFindingIntegrityReconciliationAuthorizer
            .authorizeEvidenceInvalidation(
                requestID: try HistoricalRetractionRequestID(bytes: Array(repeating: 0x41, count: 16)),
                failure: .ledgerIntegrityViolation,
                storedAuditRecord: unknownAudit
            )
        await #expect(throws: SQLiteEventJournalError.historicalRetractionTargetNotFound) {
            _ = try await repository.commitEvidenceInvalidation(unknown)
        }

        let staleAudit = try HistoricalFindingAuditRecord(
            finding: stored.finding,
            draftSHA256: HistoricalEvidenceDigest(bytes: Array(repeating: 0xA5, count: 32)),
            retraction: nil
        )
        let stale = try HistoricalFindingIntegrityReconciliationAuthorizer
            .authorizeEvidenceInvalidation(
                requestID: try HistoricalRetractionRequestID(bytes: Array(repeating: 0x42, count: 16)),
                failure: .projectionIntegrityViolation,
                storedAuditRecord: staleAudit
            )
        await #expect(throws: SQLiteEventJournalError.historicalRetractionExpectedDigestMismatch) {
            _ = try await repository.commitEvidenceInvalidation(stale)
        }
        #expect(try fixture.count("historical_finding_retraction") == 0)
        try await repository.close()
    }

    @Test("Effective queries exclude current retractions while audit reads preserve originals")
    func effectiveQueryExcludesRetractionsButAuditPreservesOriginal() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try retractionRepository(for: fixture)
        let projection = try await commitRetractionProjection(repository: repository)
        let original = projection.findings[0]
        let audit = try #require(
            try await repository.historicalFindingAuditRecord(id: original.recordID)
        )
        let before = try await repository.effectiveHistoricalFindings(
            for: ScopeID("scope-fixture"),
            through: projection.comparisonSequence,
            limit: HistoricalFindingQueryLimit(1_000)
        )
        #expect(before.contains(original))
        #expect(
            try await repository.effectiveHistoricalFindings(
                for: ScopeID("scope-fixture"),
                through: projection.baselineSequence,
                limit: HistoricalFindingQueryLimit(1_000)
            ).isEmpty
        )
        #expect(
            try await repository.historicalFindingAuditRecord(
                id: HistoricalFindingRecordID(9_999)
            ) == nil
        )

        let command = try HistoricalFindingIntegrityReconciliationAuthorizer
            .authorizeEvidenceInvalidation(
                requestID: try HistoricalRetractionRequestID(bytes: Array(repeating: 0x51, count: 16)),
                failure: .ledgerIntegrityViolation,
                storedAuditRecord: audit
            )
        _ = try await repository.commitEvidenceInvalidation(command)

        let after = try await repository.effectiveHistoricalFindings(
            for: ScopeID("scope-fixture"),
            through: projection.comparisonSequence,
            limit: HistoricalFindingQueryLimit(1_000)
        )
        #expect(after.contains(where: { $0.recordID == original.recordID }) == false)
        let preserved = try #require(
            try await repository.historicalFindingAuditRecord(id: original.recordID)
        )
        #expect(preserved.finding == audit.finding)
        #expect(preserved.draftSHA256 == audit.draftSHA256)
        #expect(preserved.retraction != nil)
        try await repository.close()
    }

    @Test("Query limits are applied after reconstructed-key ordering, never SHA ordering")
    func limitFollowsReconstructedKeyOrdering() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try retractionRepository(for: fixture, generationByte: 0x22)
        let comparisonSequence = try await commitDecreasingProjection(repository: repository)

        let complete = try await repository.effectiveHistoricalFindings(
            for: ScopeID("query-order-scope"),
            through: comparisonSequence,
            limit: HistoricalFindingQueryLimit(1_000)
        )
        #expect(complete.count == 13)
        #expect(complete.allSatisfy { $0.positiveRank == nil })
        let expected = complete.sorted(by: effectiveFindingOrder)
        #expect(complete == expected)

        let first = try await repository.effectiveHistoricalFindings(
            for: ScopeID("query-order-scope"),
            through: comparisonSequence,
            limit: HistoricalFindingQueryLimit(1)
        )
        #expect(first == Array(expected.prefix(1)))

        let shaFirstID = try fixture.int(
            "SELECT finding_id FROM historical_finding ORDER BY finding_key_sha256 LIMIT 1"
        )
        #expect(shaFirstID != expected[0].recordID.rawValue)
        try await repository.close()
    }

    @Test("v11 exposes no replacement or successor schema surface")
    func schemaHasNoReplacementSurface() throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try retractionRepository(for: fixture)
        _ = repository
        let forbidden = try fixture.int(
            "SELECT count(*) FROM sqlite_schema WHERE lower(sql) LIKE '%successor%' OR lower(sql) LIKE '%supersession%' OR lower(sql) LIKE '%replacement%'"
        )
        #expect(forbidden == 0)
    }
}

private func commitDecreasingProjection(
    repository: SQLiteEventJournalRepository
) async throws -> ObservationCommitSequence {
    try await prepareDecreasingFrame(
        repository: repository,
        observedAtMilliseconds: 2_000_000_000_000,
        childLogicalBytes: 40,
        childAllocatedBytes: 32
    )
    try await prepareDecreasingFrame(
        repository: repository,
        observedAtMilliseconds: 2_000_000_100_000,
        childLogicalBytes: 30,
        childAllocatedBytes: 24
    )
    let work = try #require(try await repository.nextHistoricalProjectionWork())
    let baseline = try #require(
        try await repository.historicalObservationFrame(sequence: work.baselineSequence)
    )
    let comparison = try #require(
        try await repository.historicalObservationFrame(sequence: work.comparisonSequence)
    )
    let result = try HistoricalFindingGenerator().generate(
        baseline: baseline,
        comparison: comparison,
        positiveLimit: work.positiveLimit
    )
    _ = try await repository.commitHistoricalProjection(result, for: work)
    return work.comparisonSequence
}

private func prepareDecreasingFrame(
    repository: SQLiteEventJournalRepository,
    observedAtMilliseconds: Int64,
    childLogicalBytes: Int64,
    childAllocatedBytes: Int64
) async throws {
    let streamID = try EventStreamID("query-order-stream")
    let rootPath = try DirtyRegionPath("/QueryOrder")
    try await repository.markDirty(
        streamID: streamID,
        regions: [
            try DirtyRegion(
                path: rootPath,
                reasons: [.contentModified, .requiresCalibration],
                maximumCursor: EventJournalCursor(UInt64(observedAtMilliseconds))
            ),
        ]
    )
    let workItem = try #require(
        try await repository.pendingDirtyWork(for: streamID, limit: 1).first
    )
    let runID = try await repository.beginCalibration(
        CalibrationRequest(streamID: streamID, workItem: workItem)
    )
    let childCount: Int64 = 12
    let rootLogical = childLogicalBytes * childCount + 100
    let rootAllocated = childAllocatedBytes * childCount + 80
    var aggregates = [
        try DirectoryMetadataAggregate(
            path: rootPath,
            logicalBytes: ByteCount(rootLogical),
            allocatedBytes: ByteCount(rootAllocated),
            descendantCount: childCount,
            coverage: .complete
        ),
    ]
    var nodes = [
        try historicalLedgerNode(
            subject: "root",
            parent: nil,
            location: "root-location",
            path: "/QueryOrder",
            displayName: "QueryOrder",
            state: .present(
                logicalBytes: ByteCount(rootLogical),
                allocatedBytes: ByteCount(rootAllocated),
                measurementCoverage: .complete
            ),
            childrenCoverage: .complete,
            observedAtMilliseconds: observedAtMilliseconds
        ),
    ]
    for index in 0..<childCount {
        let name = String(format: "Child-%02lld", index)
        let path = "/QueryOrder/\(name)"
        aggregates.append(
            try DirectoryMetadataAggregate(
                path: DirtyRegionPath(path),
                logicalBytes: ByteCount(childLogicalBytes),
                allocatedBytes: ByteCount(childAllocatedBytes),
                descendantCount: 0,
                coverage: .complete
            )
        )
        nodes.append(
            try historicalLedgerNode(
                subject: "subject-\(name)",
                parent: "root",
                location: "location-\(name)",
                path: path,
                displayName: name,
                state: .present(
                    logicalBytes: ByteCount(childLogicalBytes),
                    allocatedBytes: ByteCount(childAllocatedBytes),
                    measurementCoverage: .complete
                ),
                childrenCoverage: .complete,
                observedAtMilliseconds: observedAtMilliseconds + index + 1
            )
        )
    }
    try await repository.stageCalibration(aggregates, in: runID)
    let report = try CalibrationReport(
        coverage: .complete,
        entriesVisited: Int64(aggregates.count),
        directoriesStaged: Int64(aggregates.count),
        gaps: []
    )
    let observation = try HistoricalPairedObservationCandidate(
        rootSubjectID: SubjectID("root"),
        rootPath: "/QueryOrder",
        nodes: nodes,
        scopeID: ScopeID("query-order-scope"),
        volumeID: ObservationVolumeID("query-order-volume"),
        mountGenerationID: ObservationMountGenerationID("query-order-mount"),
        coverageEpochID: ObservationCoverageEpochID("query-order-coverage"),
        pathSemanticsVersion: ObservationSemanticsVersion(1),
        measurementSemanticsVersion: ObservationSemanticsVersion(1)
    )
    let outcome = try await repository.finalizeCalibrationWithHistoricalFrames(
        try HistoricalCalibrationFinalizationRequest(
            runID: runID,
            report: report,
            workItem: workItem,
            streamID: streamID,
            observation: observation
        )
    )
    guard case .published = outcome else {
        Issue.record("Expected the decreasing frame to publish.")
        return
    }
}

private struct RetractionProjectionFixture {
    let baselineSequence: ObservationCommitSequence
    let comparisonSequence: ObservationCommitSequence
    let findings: [EffectiveHistoricalFinding]
}

private func commitRetractionProjection(
    repository: SQLiteEventJournalRepository
) async throws -> RetractionProjectionFixture {
    let first = try await prepareHistoricalLedgerRun(repository: repository)
    _ = try await repository.finalizeCalibrationWithHistoricalFrames(first.request)
    let second = try await prepareHistoricalLedgerRun(
        repository: repository,
        logicalRootBytes: 120,
        allocatedRootBytes: 96,
        child: .present(logical: 50, allocated: 40),
        observedAtMilliseconds: 2_000_000_100_000
    )
    _ = try await repository.finalizeCalibrationWithHistoricalFrames(second.request)
    let work = try #require(try await repository.nextHistoricalProjectionWork())
    let baseline = try #require(
        try await repository.historicalObservationFrame(sequence: work.baselineSequence)
    )
    let comparison = try #require(
        try await repository.historicalObservationFrame(sequence: work.comparisonSequence)
    )
    let result = try HistoricalFindingGenerator().generate(
        baseline: baseline,
        comparison: comparison,
        positiveLimit: work.positiveLimit
    )
    _ = try await repository.commitHistoricalProjection(result, for: work)
    let findings = try await repository.effectiveHistoricalFindings(
        for: ScopeID("scope-fixture"),
        through: work.comparisonSequence,
        limit: HistoricalFindingQueryLimit(1_000)
    )
    return RetractionProjectionFixture(
        baselineSequence: work.baselineSequence,
        comparisonSequence: work.comparisonSequence,
        findings: findings
    )
}

private func effectiveFindingOrder(
    _ lhs: EffectiveHistoricalFinding,
    _ rhs: EffectiveHistoricalFinding
) -> Bool {
    if lhs.comparisonSequence != rhs.comparisonSequence {
        return lhs.comparisonSequence > rhs.comparisonSequence
    }
    switch (lhs.positiveRank, rhs.positiveRank) {
    case let (.some(left), .some(right)) where left != right:
        return left < right
    case (.some, .none):
        return true
    case (.none, .some):
        return false
    default:
        break
    }
    if lhs.draft.key != rhs.draft.key {
        return lhs.draft.key < rhs.draft.key
    }
    return lhs.recordID < rhs.recordID
}

private func retractionRepository(
    for fixture: HistoricalLedgerTestFixture,
    failurePoint: SQLiteEventJournalTestFailurePoint? = nil,
    generationByte: UInt8 = 0x11
) throws -> SQLiteEventJournalRepository {
    try SQLiteEventJournalRepository(
        databaseURL: fixture.databaseURL,
        failurePoint: failurePoint,
        now: { Date(timeIntervalSince1970: 2_000_000_010) },
        historicalStoreGenerationProvider: { Array(repeating: generationByte, count: 16) }
    )
}

private func retractionDigestHex(
    _ command: HistoricalFindingEvidenceInvalidationCommand
) -> String {
    var bytes = Data("SpaceTrace.HistoricalFindingRetractionRequest".utf8)
    bytes.append(0)
    appendBigEndian(UInt32(1), to: &bytes)
    bytes.append(contentsOf: command.requestID.bytes)
    appendBigEndian(UInt64(command.findingID.rawValue), to: &bytes)
    bytes.append(contentsOf: command.expectedDraftSHA256.bytes)
    let reason = Data("evidence_invalidated".utf8)
    appendBigEndian(UInt64(reason.count), to: &bytes)
    bytes.append(reason)
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

private func appendBigEndian<T: FixedWidthInteger>(
    _ value: T,
    to data: inout Data
) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}
