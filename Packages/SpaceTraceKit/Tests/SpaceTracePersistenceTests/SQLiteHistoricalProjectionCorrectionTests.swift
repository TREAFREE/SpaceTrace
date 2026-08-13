import Foundation
import SpaceTraceApplication
import SpaceTraceDomain
import Testing
@testable import SpaceTracePersistence

@Suite("SQLite registered historical projection corrections", .serialized)
struct SQLiteHistoricalProjectionCorrectionTests {
    @Test("A corrected finding has its own typed append-only invalidation target")
    func correctedFindingInvalidation() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let registry = try correctionPersistenceRegistry()
        let repository = try correctionPersistenceRepository(
            fixture: fixture,
            registry: registry
        )
        let rootProjectionID = try await correctionRootProjection(repository: repository)
        let service = HistoricalProjectionCorrectionService(
            repository: repository,
            registry: registry
        )
        _ = try await service.correct(
            rootProjectionID: rootProjectionID,
            requestID: correctionRequestID(0x08),
            input: correctionPersistenceInput("corrected-invalidation"),
            algorithmVersion: HistoricalFindingAlgorithmVersion(1),
            rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
        )
        let findingID = try HistoricalCorrectedFindingRecordID(
            fixture.int("SELECT min(corrected_finding_id) FROM historical_corrected_finding")
        )
        let audit = try #require(
            try await repository.historicalCorrectedFindingIntegrityAuditRecord(id: findingID)
        )
        let command = try HistoricalCorrectedFindingIntegrityReconciliationAuthorizer
            .authorizeEvidenceInvalidation(
                requestID: HistoricalRetractionRequestID(
                    bytes: Array(repeating: 0x81, count: 16)
                ),
                failure: .projectionIntegrityViolation,
                storedAuditRecord: audit
            )

        let outcome = try await repository.commitCorrectedEvidenceInvalidation(command)
        guard case .newlyCommitted(let receipt) = outcome else {
            Issue.record("Expected a new corrected-finding invalidation.")
            return
        }
        #expect(receipt.findingID == findingID)
        #expect(receipt.expiresAt >= receipt.committedAt)
        #expect(try fixture.count("historical_corrected_finding_retraction") == 1)
        #expect(try fixture.count("historical_finding_retraction") == 0)
        let reloaded = try #require(
            try await repository.historicalCorrectedFindingIntegrityAuditRecord(id: findingID)
        )
        #expect(reloaded.retraction == receipt)
        let comparisonSequence = try ObservationCommitSequence(
            fixture.int("SELECT comparison_sequence FROM historical_projection_work LIMIT 1")
        )
        let effective = try await repository.versionedEffectiveHistoricalFindings(
            for: ScopeID("scope-fixture"),
            through: comparisonSequence,
            limit: HistoricalFindingQueryLimit(100)
        )
        #expect(effective.contains(where: { $0.recordID == .corrected(findingID) }) == false)
        #expect(effective.allSatisfy {
            if case .corrected = $0.recordID { return true }
            return false
        })
        let invalidated = try await repository
            .versionedEvidenceInvalidatedHistoricalFindingAuditRecords(
                for: ScopeID("scope-fixture"),
                through: comparisonSequence,
                limit: HistoricalFindingQueryLimit(100)
            )
        #expect(invalidated.map(\.finding.recordID).contains(.corrected(findingID)))
        try await repository.close()
    }

    @Test("Corrected invalidation survives ACK loss and conflicting retries fail closed")
    func correctedInvalidationRetryAndConflict() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let registry = try correctionPersistenceRegistry()
        var repository = try correctionPersistenceRepository(
            fixture: fixture,
            registry: registry,
            failurePoint: .afterHistoricalCorrectedRetractionCommitBeforeReturningReceipt
        )
        let rootProjectionID = try await correctionRootProjection(repository: repository)
        let service = HistoricalProjectionCorrectionService(
            repository: repository,
            registry: registry
        )
        _ = try await service.correct(
            rootProjectionID: rootProjectionID,
            requestID: correctionRequestID(0x09),
            input: correctionPersistenceInput("corrected-retry"),
            algorithmVersion: HistoricalFindingAlgorithmVersion(1),
            rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
        )
        let findingID = try HistoricalCorrectedFindingRecordID(
            fixture.int("SELECT min(corrected_finding_id) FROM historical_corrected_finding")
        )
        let audit = try #require(
            try await repository.historicalCorrectedFindingIntegrityAuditRecord(id: findingID)
        )
        let requestID = try HistoricalRetractionRequestID(
            bytes: Array(repeating: 0x82, count: 16)
        )
        let command = try HistoricalCorrectedFindingIntegrityReconciliationAuthorizer
            .authorizeEvidenceInvalidation(
                requestID: requestID,
                failure: .ledgerIntegrityViolation,
                storedAuditRecord: audit
            )

        await #expect(throws: SQLiteEventJournalError.injectedFailure) {
            _ = try await repository.commitCorrectedEvidenceInvalidation(command)
        }
        #expect(try fixture.count("historical_corrected_finding_retraction") == 1)
        try await repository.close()

        repository = try correctionPersistenceRepository(fixture: fixture, registry: registry)
        let retry = try await repository.commitCorrectedEvidenceInvalidation(command)
        guard case .alreadyCommitted(let receipt) = retry else {
            Issue.record("Expected exact corrected invalidation retry to rehydrate.")
            return
        }
        #expect(receipt.findingID == findingID)

        let conflictingCommand = try HistoricalCorrectedFindingIntegrityReconciliationAuthorizer
            .authorizeEvidenceInvalidation(
                requestID: HistoricalRetractionRequestID(
                    bytes: Array(repeating: 0x83, count: 16)
                ),
                failure: .projectionIntegrityViolation,
                storedAuditRecord: audit
            )
        await #expect(throws: SQLiteEventJournalError.historicalCorrectedRetractionImmutableConflict) {
            _ = try await repository.commitCorrectedEvidenceInvalidation(conflictingCommand)
        }
        #expect(try fixture.count("historical_corrected_finding_retraction") == 1)
        try await repository.close()
    }

    @Test("Corrected invalidation rolls back before commit and rejects unknown or stale evidence")
    func correctedInvalidationRollbackAndEvidenceValidation() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let registry = try correctionPersistenceRegistry()
        let repository = try correctionPersistenceRepository(
            fixture: fixture,
            registry: registry,
            failurePoint: .beforeHistoricalCorrectedRetractionCommit
        )
        let rootProjectionID = try await correctionRootProjection(repository: repository)
        let service = HistoricalProjectionCorrectionService(
            repository: repository,
            registry: registry
        )
        _ = try await service.correct(
            rootProjectionID: rootProjectionID,
            requestID: correctionRequestID(0x0A),
            input: correctionPersistenceInput("corrected-rollback"),
            algorithmVersion: HistoricalFindingAlgorithmVersion(1),
            rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
        )
        let findingID = try HistoricalCorrectedFindingRecordID(
            fixture.int("SELECT min(corrected_finding_id) FROM historical_corrected_finding")
        )
        let audit = try #require(
            try await repository.historicalCorrectedFindingIntegrityAuditRecord(id: findingID)
        )
        let command = try HistoricalCorrectedFindingIntegrityReconciliationAuthorizer
            .authorizeEvidenceInvalidation(
                requestID: HistoricalRetractionRequestID(
                    bytes: Array(repeating: 0x84, count: 16)
                ),
                failure: .ledgerIntegrityViolation,
                storedAuditRecord: audit
            )
        await #expect(throws: SQLiteEventJournalError.injectedFailure) {
            _ = try await repository.commitCorrectedEvidenceInvalidation(command)
        }
        #expect(try fixture.count("historical_corrected_finding_retraction") == 0)

        let staleAudit = try HistoricalCorrectedFindingIntegrityAuditRecord(
            findingID: findingID,
            projectionID: audit.projectionID,
            draftSHA256: HistoricalEvidenceDigest(
                bytes: Array(repeating: 0xA5, count: 32)
            ),
            retraction: nil
        )
        let stale = try HistoricalCorrectedFindingIntegrityReconciliationAuthorizer
            .authorizeEvidenceInvalidation(
                requestID: HistoricalRetractionRequestID(
                    bytes: Array(repeating: 0x85, count: 16)
                ),
                failure: .projectionIntegrityViolation,
                storedAuditRecord: staleAudit
            )
        await #expect(
            throws: SQLiteEventJournalError
                .historicalCorrectedRetractionExpectedDigestMismatch
        ) {
            _ = try await repository.commitCorrectedEvidenceInvalidation(stale)
        }

        let unknownAudit = try HistoricalCorrectedFindingIntegrityAuditRecord(
            findingID: HistoricalCorrectedFindingRecordID(9_999),
            projectionID: audit.projectionID,
            draftSHA256: audit.draftSHA256,
            retraction: nil
        )
        let unknown = try HistoricalCorrectedFindingIntegrityReconciliationAuthorizer
            .authorizeEvidenceInvalidation(
                requestID: HistoricalRetractionRequestID(
                    bytes: Array(repeating: 0x86, count: 16)
                ),
                failure: .ledgerIntegrityViolation,
                storedAuditRecord: unknownAudit
            )
        await #expect(
            throws: SQLiteEventJournalError.historicalCorrectedRetractionTargetNotFound
        ) {
            _ = try await repository.commitCorrectedEvidenceInvalidation(unknown)
        }
        #expect(try fixture.count("historical_corrected_finding_retraction") == 0)
        try await repository.close()
    }

    @Test("A superseded corrected finding cannot be invalidated through API or direct SQL")
    func supersededCorrectedFindingCannotBeInvalidated() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let registry = try correctionPersistenceRegistry()
        let repository = try correctionPersistenceRepository(
            fixture: fixture,
            registry: registry
        )
        let rootProjectionID = try await correctionRootProjection(repository: repository)
        let service = HistoricalProjectionCorrectionService(
            repository: repository,
            registry: registry
        )
        _ = try await service.correct(
            rootProjectionID: rootProjectionID,
            requestID: correctionRequestID(0x0B),
            input: correctionPersistenceInput("first-correction"),
            algorithmVersion: HistoricalFindingAlgorithmVersion(1),
            rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
        )
        let predecessorFindingID = try HistoricalCorrectedFindingRecordID(
            fixture.int("SELECT min(corrected_finding_id) FROM historical_corrected_finding")
        )
        let predecessorAudit = try #require(
            try await repository.historicalCorrectedFindingIntegrityAuditRecord(
                id: predecessorFindingID
            )
        )
        let predecessorCommand = try HistoricalCorrectedFindingIntegrityReconciliationAuthorizer
            .authorizeEvidenceInvalidation(
                requestID: HistoricalRetractionRequestID(
                    bytes: Array(repeating: 0x87, count: 16)
                ),
                failure: .ledgerIntegrityViolation,
                storedAuditRecord: predecessorAudit
            )
        _ = try await service.correct(
            rootProjectionID: rootProjectionID,
            requestID: correctionRequestID(0x0C),
            input: correctionPersistenceInput("second-correction"),
            algorithmVersion: HistoricalFindingAlgorithmVersion(1),
            rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
        )

        #expect(
            try await repository.historicalCorrectedFindingIntegrityAuditRecord(
                id: predecessorFindingID
            ) == nil
        )
        await #expect(
            throws: SQLiteEventJournalError.historicalCorrectedRetractionTargetNotFound
        ) {
            _ = try await repository.commitCorrectedEvidenceInvalidation(predecessorCommand)
        }
        try await repository.close()

        #expect(throws: (any Error).self) {
            try fixture.execute(
                """
                INSERT INTO historical_corrected_finding_retraction(
                    request_format_version,request_id,canonical_request_sha256,
                    retracted_corrected_finding_id,expected_draft_sha256,
                    reason_code,committed_at_ms,expires_at_ms
                )
                SELECT 1,X'88888888888888888888888888888888',randomblob(32),
                       corrected_finding_id,draft_sha256,1,0,expires_at_ms
                FROM historical_corrected_finding
                WHERE corrected_finding_id=\(predecessorFindingID.rawValue)
                """
            )
        }
        #expect(try fixture.count("historical_corrected_finding_retraction") == 0)
    }

    @Test("A registered same-frame correction commits a complete checkpointed projection")
    func commitsRegisteredCorrection() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let registry = try correctionPersistenceRegistry()
        let repository = try correctionPersistenceRepository(
            fixture: fixture,
            registry: registry
        )
        let rootProjectionID = try await correctionRootProjection(repository: repository)
        let service = HistoricalProjectionCorrectionService(
            repository: repository,
            registry: registry
        )

        let outcome = try await service.correct(
            rootProjectionID: rootProjectionID,
            requestID: correctionRequestID(0x11),
            input: try correctionPersistenceInput("correction-one"),
            algorithmVersion: HistoricalFindingAlgorithmVersion(1),
            rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
        )

        #expect(outcome == .newlyCommitted(try HistoricalCorrectingProjectionRecordID(1)))
        #expect(try fixture.count("historical_correction_input") == 1)
        #expect(try fixture.count("historical_projection_correction_work") == 1)
        #expect(try fixture.count("historical_correcting_projection") == 1)
        #expect(try fixture.count("historical_projection_correction_checkpoint") == 1)
        #expect(try fixture.count("historical_corrected_finding") > 0)
        #expect(try fixture.count("historical_finding_projection") == 1)
        try await repository.close()
    }

    @Test("Only the terminal correction is current while every version remains auditable")
    func terminalCorrectionDefinesCurrentEffectiveView() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let registry = try correctionPersistenceRegistry()
        let repository = try correctionPersistenceRepository(
            fixture: fixture,
            registry: registry
        )
        let rootProjectionID = try await correctionRootProjection(repository: repository)
        let comparisonSequence = try ObservationCommitSequence(
            fixture.int("SELECT comparison_sequence FROM historical_projection_work LIMIT 1")
        )
        let service = HistoricalProjectionCorrectionService(
            repository: repository,
            registry: registry
        )

        let original = try await repository.versionedEffectiveHistoricalFindings(
            for: ScopeID("scope-fixture"),
            through: comparisonSequence,
            limit: HistoricalFindingQueryLimit(100)
        )
        #expect(original.isEmpty == false)
        #expect(original.allSatisfy {
            if case .original = $0.recordID { return true }
            return false
        })

        let first = try await service.correct(
            rootProjectionID: rootProjectionID,
            requestID: correctionRequestID(0x61),
            input: correctionPersistenceInput("terminal-one"),
            algorithmVersion: HistoricalFindingAlgorithmVersion(1),
            rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
        )
        let firstID = try correctingProjectionID(first)
        let firstEffective = try await repository.versionedEffectiveHistoricalFindings(
            for: ScopeID("scope-fixture"),
            through: comparisonSequence,
            limit: HistoricalFindingQueryLimit(100)
        )
        #expect(firstEffective.isEmpty == false)
        #expect(firstEffective.allSatisfy { finding in
            guard finding.projectionID == .correcting(firstID) else { return false }
            if case .corrected = finding.recordID { return true }
            return false
        })

        let second = try await service.correct(
            rootProjectionID: rootProjectionID,
            requestID: correctionRequestID(0x62),
            input: correctionPersistenceInput("terminal-two"),
            algorithmVersion: HistoricalFindingAlgorithmVersion(1),
            rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
        )
        let secondID = try correctingProjectionID(second)
        let terminal = try await repository.versionedEffectiveHistoricalFindings(
            for: ScopeID("scope-fixture"),
            through: comparisonSequence,
            limit: HistoricalFindingQueryLimit(100)
        )
        #expect(terminal.isEmpty == false)
        #expect(terminal.allSatisfy { $0.projectionID == .correcting(secondID) })
        #expect(terminal.contains(where: { $0.projectionID == .correcting(firstID) }) == false)

        let bounded = try await repository.versionedEffectiveHistoricalFindings(
            for: ScopeID("scope-fixture"),
            through: comparisonSequence,
            limit: HistoricalFindingQueryLimit(1)
        )
        #expect(bounded == Array(terminal.prefix(1)))

        let audit = try await repository.versionedHistoricalFindingAuditRecords(
            for: ScopeID("scope-fixture"),
            through: comparisonSequence,
            limit: HistoricalFindingQueryLimit(100)
        )
        #expect(audit.contains(where: {
            if case .original = $0.finding.recordID { return true }
            return false
        }))
        #expect(audit.contains(where: { $0.finding.projectionID == .correcting(firstID) }))
        #expect(audit.contains(where: { $0.finding.projectionID == .correcting(secondID) }))
        let originalOne = try HistoricalFindingRecordID(1)
        let correctedOne = try HistoricalCorrectedFindingRecordID(1)
        #expect(
            audit.contains(where: { $0.finding.recordID == .original(originalOne) })
        )
        #expect(
            audit.contains(where: {
                $0.finding.recordID == .corrected(correctedOne)
            })
        )
        try await repository.close()
    }

    @Test("An empty terminal correction never revives original findings")
    func emptyTerminalCorrectionDoesNotFallBack() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let registry = try correctionPersistenceRegistry()
        let repository = try correctionPersistenceRepository(
            fixture: fixture,
            registry: registry
        )
        let rootProjectionID = try await correctionRootProjection(repository: repository)
        let comparisonSequence = try ObservationCommitSequence(
            fixture.int("SELECT comparison_sequence FROM historical_projection_work LIMIT 1")
        )
        #expect(try await repository.versionedEffectiveHistoricalFindings(
            for: ScopeID("scope-fixture"),
            through: comparisonSequence,
            limit: HistoricalFindingQueryLimit(100)
        ).isEmpty == false)

        let service = HistoricalProjectionCorrectionService(
            repository: repository,
            registry: registry
        )
        _ = try await service.correct(
            rootProjectionID: rootProjectionID,
            requestID: correctionRequestID(0x63),
            input: correctionPersistenceInput("empty-terminal"),
            algorithmVersion: HistoricalFindingAlgorithmVersion(1),
            rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
        )

        #expect(try fixture.count("historical_corrected_finding") == 0)
        #expect(try await repository.versionedEffectiveHistoricalFindings(
            for: ScopeID("scope-fixture"),
            through: comparisonSequence,
            limit: HistoricalFindingQueryLimit(100)
        ).isEmpty)
        let audit = try await repository.versionedHistoricalFindingAuditRecords(
            for: ScopeID("scope-fixture"),
            through: comparisonSequence,
            limit: HistoricalFindingQueryLimit(100)
        )
        #expect(audit.isEmpty == false)
        #expect(audit.allSatisfy {
            if case .original = $0.finding.recordID { return true }
            return false
        })
        try await repository.close()
    }

    @Test("Retention removes corrected invalidations before their terminal finding graph")
    func retentionDeletesCorrectedRetractionGraph() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let registry = try correctionPersistenceRegistry()
        let repository = try correctionPersistenceRepository(
            fixture: fixture,
            registry: registry
        )
        let rootProjectionID = try await correctionRootProjection(repository: repository)
        let service = HistoricalProjectionCorrectionService(
            repository: repository,
            registry: registry
        )
        _ = try await service.correct(
            rootProjectionID: rootProjectionID,
            requestID: correctionRequestID(0x64),
            input: correctionPersistenceInput("retention-correction"),
            algorithmVersion: HistoricalFindingAlgorithmVersion(1),
            rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
        )
        let findingID = try HistoricalCorrectedFindingRecordID(
            fixture.int("SELECT min(corrected_finding_id) FROM historical_corrected_finding")
        )
        let audit = try #require(
            try await repository.historicalCorrectedFindingIntegrityAuditRecord(id: findingID)
        )
        let command = try HistoricalCorrectedFindingIntegrityReconciliationAuthorizer
            .authorizeEvidenceInvalidation(
                requestID: HistoricalRetractionRequestID(
                    bytes: Array(repeating: 0x89, count: 16)
                ),
                failure: .ledgerIntegrityViolation,
                storedAuditRecord: audit
            )
        _ = try await repository.commitCorrectedEvidenceInvalidation(command)
        #expect(try fixture.count("historical_corrected_finding_retraction") == 1)

        _ = try await repository.applyRetention(
            referenceDate: Date(
                timeIntervalSince1970: Double(2_000_000_100_000 + 2_592_000_001) / 1_000
            )
        )
        for table in [
            "historical_corrected_finding_retraction",
            "historical_corrected_finding",
            "historical_correcting_projection",
            "historical_projection_correction_work",
            "historical_finding_projection",
            "historical_observation_batch",
        ] {
            #expect(try fixture.count(table) == 0, "Expected \(table) to be empty")
        }
        #expect(try fixture.int("SELECT count(*) FROM pragma_foreign_key_check") == 0)
        try await repository.close()
    }

    @Test("Commit acknowledgement loss retries byte-identically without another edge")
    func acknowledgementLossIsIdempotent() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let registry = try correctionPersistenceRegistry()
        var repository = try correctionPersistenceRepository(
            fixture: fixture,
            registry: registry,
            failurePoint: .afterHistoricalCorrectionCommitBeforeReturningReceipt
        )
        let rootProjectionID = try await correctionRootProjection(repository: repository)
        let requestID = try correctionRequestID(0x22)
        let input = try correctionPersistenceInput("correction-retry")
        var service = HistoricalProjectionCorrectionService(
            repository: repository,
            registry: registry
        )

        await #expect(throws: SQLiteEventJournalError.injectedFailure) {
            _ = try await service.correct(
                rootProjectionID: rootProjectionID,
                requestID: requestID,
                input: input,
                algorithmVersion: HistoricalFindingAlgorithmVersion(1),
                rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
            )
        }
        #expect(try fixture.count("historical_correcting_projection") == 1)
        try await repository.close()

        repository = try correctionPersistenceRepository(
            fixture: fixture,
            registry: registry
        )
        service = HistoricalProjectionCorrectionService(
            repository: repository,
            registry: registry
        )
        let retry = try await service.correct(
            rootProjectionID: rootProjectionID,
            requestID: requestID,
            input: input,
            algorithmVersion: HistoricalFindingAlgorithmVersion(1),
            rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
        )
        #expect(retry == .alreadyCommitted(try HistoricalCorrectingProjectionRecordID(1)))
        #expect(try fixture.count("historical_projection_correction_work") == 1)
        #expect(try fixture.count("historical_correcting_projection") == 1)
        #expect(try fixture.count("historical_projection_correction_checkpoint") == 1)
        try await repository.close()
    }

    @Test("A changed field under one request ID is an immutable conflict")
    func requestConflict() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let registry = try correctionPersistenceRegistry()
        let repository = try correctionPersistenceRepository(
            fixture: fixture,
            registry: registry
        )
        let rootProjectionID = try await correctionRootProjection(repository: repository)
        let service = HistoricalProjectionCorrectionService(
            repository: repository,
            registry: registry
        )
        let requestID = try correctionRequestID(0x33)
        _ = try await service.correct(
            rootProjectionID: rootProjectionID,
            requestID: requestID,
            input: correctionPersistenceInput("first-input"),
            algorithmVersion: HistoricalFindingAlgorithmVersion(1),
            rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
        )

        await #expect(
            throws: HistoricalProjectionCorrectionServiceError.immutableRequestConflict
        ) {
            _ = try await service.correct(
                rootProjectionID: rootProjectionID,
                requestID: requestID,
                input: correctionPersistenceInput("changed-input"),
                algorithmVersion: HistoricalFindingAlgorithmVersion(1),
                rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
            )
        }
        #expect(try fixture.count("historical_projection_correction_work") == 1)
        try await repository.close()
    }

    @Test("Checkpoint failure rolls every correction row back")
    func checkpointFailureRollsBack() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let registry = try correctionPersistenceRegistry()
        let repository = try correctionPersistenceRepository(
            fixture: fixture,
            registry: registry,
            failurePoint: .beforeHistoricalCorrectionCheckpoint
        )
        let rootProjectionID = try await correctionRootProjection(repository: repository)
        let service = HistoricalProjectionCorrectionService(
            repository: repository,
            registry: registry
        )

        await #expect(throws: SQLiteEventJournalError.injectedFailure) {
            _ = try await service.correct(
                rootProjectionID: rootProjectionID,
                requestID: correctionRequestID(0x44),
                input: correctionPersistenceInput("rollback-input"),
                algorithmVersion: HistoricalFindingAlgorithmVersion(1),
                rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
            )
        }
        #expect(try fixture.count("historical_correction_input") == 0)
        #expect(try fixture.count("historical_projection_correction_work") == 0)
        #expect(try fixture.count("historical_correcting_projection") == 0)
        #expect(try fixture.count("historical_corrected_finding") == 0)
        #expect(try fixture.count("historical_projection_correction_checkpoint") == 0)
        #expect(try fixture.count("historical_finding_projection") == 1)
        try await repository.close()
    }

    @Test("An empty deterministic replacement is committed without a fabricated finding")
    func commitsEmptyReplacement() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let registry = try correctionPersistenceRegistry()
        let repository = try correctionPersistenceRepository(
            fixture: fixture,
            registry: registry
        )
        let rootProjectionID = try await correctionRootProjection(
            repository: repository,
            changedBytes: false
        )
        let service = HistoricalProjectionCorrectionService(
            repository: repository,
            registry: registry
        )

        _ = try await service.correct(
            rootProjectionID: rootProjectionID,
            requestID: correctionRequestID(0x55),
            input: correctionPersistenceInput("empty-input"),
            algorithmVersion: HistoricalFindingAlgorithmVersion(1),
            rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
        )

        #expect(try fixture.count("historical_correcting_projection") == 1)
        #expect(try fixture.count("historical_corrected_finding") == 0)
        #expect(try fixture.int(
            "SELECT finding_count FROM historical_correcting_projection"
        ) == 0)
        try await repository.close()
    }
}

private func correctionPersistenceRegistry() throws -> HistoricalProjectionCorrectionRegistry {
    try HistoricalProjectionCorrectionRegistry(
        implementations: [
            HistoricalProjectionCorrectionImplementation(
                algorithmVersion: HistoricalFindingAlgorithmVersion(1),
                rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1),
                correctionInputFormatVersion: HistoricalCorrectionInputFormatVersion(1)
            ) { input, baseline, comparison, positiveLimit in
                guard input.isEmpty == false else {
                    throw HistoricalProjectionCorrectionRegistryError.invalidCanonicalInput
                }
                if input == Data("empty-terminal".utf8) {
                    return try HistoricalFindingGenerator().generate(
                        baseline: baseline,
                        comparison: correctionFrameWithBaselineMeasurements(
                            baseline: baseline,
                            comparison: comparison
                        ),
                        positiveLimit: positiveLimit
                    )
                }
                return try HistoricalFindingGenerator().generate(
                    baseline: baseline,
                    comparison: comparison,
                    positiveLimit: positiveLimit
                )
            },
        ]
    )
}

private func correctingProjectionID(
    _ outcome: HistoricalProjectionCorrectionCommitOutcome
) throws -> HistoricalCorrectingProjectionRecordID {
    switch outcome {
    case .newlyCommitted(let id), .alreadyCommitted(let id):
        return id
    }
}

private func correctionFrameWithBaselineMeasurements(
    baseline: HistoricalFindingObservationFrame,
    comparison: HistoricalFindingObservationFrame
) throws -> HistoricalFindingObservationFrame {
    let baselineBySubject = Dictionary(
        uniqueKeysWithValues: baseline.nodes.map { ($0.endpoint.subjectID, $0) }
    )
    let nodes = try comparison.nodes.map { node in
        let baselineNode = try #require(baselineBySubject[node.endpoint.subjectID])
        guard case .present = baselineNode.endpoint.state else {
            throw HistoricalProjectionCorrectionRegistryError.generatorFrameMismatch
        }
        let endpoint = try ObservationEndpoint(
            id: node.endpoint.id,
            scopeID: node.endpoint.scopeID,
            volumeID: node.endpoint.volumeID,
            mountGenerationID: node.endpoint.mountGenerationID,
            coverageEpochID: node.endpoint.coverageEpochID,
            subjectID: node.endpoint.subjectID,
            identityBasis: node.endpoint.identityBasis,
            locationID: node.endpoint.locationID,
            metric: node.endpoint.metric,
            pathSemanticsVersion: node.endpoint.pathSemanticsVersion,
            measurementSemanticsVersion: node.endpoint.measurementSemanticsVersion,
            sequence: node.endpoint.sequence,
            observedAt: node.endpoint.observedAt,
            state: baselineNode.endpoint.state
        )
        return try HistoricalFindingNode(
            endpoint: endpoint,
            parentSubjectID: node.parentSubjectID,
            path: node.path,
            displayName: node.displayName,
            directChildrenCoverage: node.directChildrenCoverage,
            classification: node.classification,
            stableIdentityEvidence: node.stableIdentityEvidence
        )
    }
    return try HistoricalFindingObservationFrame(
        rootSubjectID: comparison.rootSubjectID,
        rootPath: comparison.rootPath,
        nodes: nodes
    )
}

private func correctionPersistenceRepository(
    fixture: HistoricalLedgerTestFixture,
    registry: HistoricalProjectionCorrectionRegistry,
    failurePoint: SQLiteEventJournalTestFailurePoint? = nil
) throws -> SQLiteEventJournalRepository {
    try SQLiteEventJournalRepository(
        databaseURL: fixture.databaseURL,
        failurePoint: failurePoint,
        historicalProjectionCorrectionRegistry: registry
    )
}

private func correctionRootProjection(
    repository: SQLiteEventJournalRepository,
    changedBytes: Bool = true
) async throws -> HistoricalProjectionRecordID {
    let first = try await prepareHistoricalLedgerRun(
        repository: repository,
        streamName: "correction-stream",
        logicalRootBytes: 100,
        allocatedRootBytes: 80,
        child: .present(logical: 40, allocated: 32),
        observedAtMilliseconds: 2_000_000_000_000
    )
    _ = try await repository.finalizeCalibrationWithHistoricalFrames(first.request)
    let second = try await prepareHistoricalLedgerRun(
        repository: repository,
        streamName: "correction-stream",
        logicalRootBytes: changedBytes ? 120 : 100,
        allocatedRootBytes: changedBytes ? 96 : 80,
        child: .present(
            logical: changedBytes ? 50 : 40,
            allocated: changedBytes ? 40 : 32
        ),
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
    let outcome = try await repository.commitHistoricalProjection(result, for: work)
    switch outcome {
    case .newlyCommitted(let projectionID), .alreadyCommitted(let projectionID):
        return projectionID
    }
}

private func correctionRequestID(
    _ byte: UInt8
) throws -> HistoricalProjectionCorrectionRequestID {
    try HistoricalProjectionCorrectionRequestID(bytes: Array(repeating: byte, count: 16))
}

private func correctionPersistenceInput(
    _ value: String
) throws -> HistoricalProjectionCorrectionInput {
    try HistoricalProjectionCorrectionInput(
        formatVersion: HistoricalCorrectionInputFormatVersion(1),
        canonicalBytes: Data(value.utf8)
    )
}
