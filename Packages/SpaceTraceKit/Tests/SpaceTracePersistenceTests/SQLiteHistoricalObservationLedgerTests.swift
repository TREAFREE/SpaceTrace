import Foundation
import SpaceTraceApplication
import SpaceTraceDomain
import Synchronization
import Testing
@testable import SpaceTracePersistence

@Suite("SQLite immutable observation ledger", .serialized)
struct SQLiteHistoricalObservationLedgerTests {
    @Test("The first pair is a descriptive baseline and the second pair creates metric work")
    func baselineThenProjectionWork() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try repository(for: fixture)

        let first = try await prepareHistoricalLedgerRun(repository: repository)
        let firstOutcome = try await repository.finalizeCalibrationWithHistoricalFrames(
            first.request
        )
        let firstCommit = try published(firstOutcome)
        #expect(firstCommit.disposition == .newlyCommitted)
        #expect(firstCommit.logical.sequence.rawValue + 1 == firstCommit.allocated.sequence.rawValue)
        #expect(firstCommit.logical.endpointCount == 2)
        #expect(firstCommit.allocated.endpointCount == 2)
        #expect(
            firstCommit.logical.rootEndpointID.rawValue
                == "st11:11111111111111111111111111111111:0000000000000001:01"
        )
        #expect(
            firstCommit.allocated.rootEndpointID.rawValue
                == "st11:11111111111111111111111111111111:0000000000000001:02"
        )
        #expect(try fixture.count("historical_observation_baseline_checkpoint") == 2)
        #expect(try fixture.count("historical_projection_work") == 0)
        #expect(try fixture.count("directory_history_sample") == 4)
        #expect(try fixture.count("dirty_region") == 0)
        #expect(try fixture.count("node_current") == 2)
        #expect(
            try fixture.rows(
                "SELECT state FROM scan_run WHERE id='\(first.runID.rawValue)'"
            ) == [["completed"]]
        )

        let logical = try #require(
            try await repository.historicalObservationFrame(
                sequence: firstCommit.logical.sequence
            )
        )
        let allocated = try #require(
            try await repository.historicalObservationFrame(
                sequence: firstCommit.allocated.sequence
            )
        )
        #expect(logical.metric == .logical)
        #expect(allocated.metric == .allocated)
        #expect(logical.rootEndpointID == firstCommit.logical.rootEndpointID)
        #expect(allocated.rootEndpointID == firstCommit.allocated.rootEndpointID)

        let second = try await prepareHistoricalLedgerRun(
            repository: repository,
            logicalRootBytes: 120,
            allocatedRootBytes: 96,
            child: .present(logical: 50, allocated: 40),
            observedAtMilliseconds: 2_000_000_100_000,
            candidateOrderReversed: true
        )
        let secondCommit = try published(
            try await repository.finalizeCalibrationWithHistoricalFrames(second.request)
        )
        #expect(secondCommit.logical.sequence.rawValue + 1 == secondCommit.allocated.sequence.rawValue)
        #expect(try fixture.count("historical_projection_work") == 2)
        #expect(
            try fixture.rows(
                "SELECT baseline_sequence,comparison_sequence FROM historical_projection_work ORDER BY comparison_sequence"
            ) == [
                [
                    String(firstCommit.logical.sequence.rawValue),
                    String(secondCommit.logical.sequence.rawValue),
                ],
                [
                    String(firstCommit.allocated.sequence.rawValue),
                    String(secondCommit.allocated.sequence.rawValue),
                ],
            ]
        )
        try await repository.close()
    }

    @Test("Explicit absence needs an immediate prior frame and complete parent proof")
    func absenceNeedsPriorFrame() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try repository(for: fixture)

        let invalidFirst = try await prepareHistoricalLedgerRun(
            repository: repository,
            child: .absent
        )
        await #expect(
            throws: SQLiteEventJournalError.historicalFirstBaselineCannotContainAbsence
        ) {
            _ = try await repository.finalizeCalibrationWithHistoricalFrames(
                invalidFirst.request
            )
        }
        #expect(try fixture.count("historical_observation_batch") == 0)
        try await repository.discardCalibration(
            invalidFirst.runID,
            disposition: .cancelled,
            report: nil
        )

        let first = try await prepareHistoricalLedgerRun(repository: repository)
        _ = try await repository.finalizeCalibrationWithHistoricalFrames(first.request)
        let second = try await prepareHistoricalLedgerRun(
            repository: repository,
            child: .absent,
            observedAtMilliseconds: 2_000_000_100_000
        )
        let fabricatedNodes = try second.request.observation.nodes.map { node in
            guard node.subjectID.rawValue == "child" else { return node }
            return try historicalLedgerNode(
                subject: "child",
                parent: "root",
                location: "location-fabricated",
                path: "/Fixtures/Fabricated",
                displayName: "Fabricated",
                state: .absent,
                childrenCoverage: .unknown,
                observedAtMilliseconds: node.observedAt.millisecondsSince1970,
                classification: nil
            )
        }
        let fabricated = try HistoricalCalibrationFinalizationRequest(
            runID: second.runID,
            report: second.report,
            workItem: second.workItem,
            streamID: second.streamID,
            observation: HistoricalPairedObservationCandidate(
                rootSubjectID: second.request.observation.rootSubjectID,
                rootPath: second.request.observation.rootPath,
                nodes: fabricatedNodes,
                scopeID: second.request.observation.scopeID,
                volumeID: second.request.observation.volumeID,
                mountGenerationID: second.request.observation.mountGenerationID,
                coverageEpochID: second.request.observation.coverageEpochID,
                pathSemanticsVersion: second.request.observation.pathSemanticsVersion,
                measurementSemanticsVersion: second.request.observation
                    .measurementSemanticsVersion
            )
        )
        await #expect(throws: SQLiteEventJournalError.historicalAbsenceEvidenceMissing) {
            _ = try await repository.finalizeCalibrationWithHistoricalFrames(fabricated)
        }
        let commit = try published(
            try await repository.finalizeCalibrationWithHistoricalFrames(second.request)
        )
        let frame = try #require(
            try await repository.historicalObservationFrame(sequence: commit.logical.sequence)
        )
        let child = try #require(
            frame.nodes.first { $0.endpoint.subjectID.rawValue == "child" }
        )
        guard case let .absent(reference) = child.endpoint.state else {
            Issue.record("Expected an explicit absent endpoint.")
            return
        }
        #expect(reference.parentSubjectID.rawValue == "root")
        #expect(reference.parentEndpointID == frame.rootEndpointID)
        try await repository.close()
    }

    @Test("Unknown evidence round-trips and incomplete parent enumeration cannot prove absence")
    func unknownAndIncompleteAbsenceEvidence() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try repository(for: fixture)

        let unknown = try await prepareHistoricalLedgerRun(
            repository: repository,
            child: .unknown(.permissionDenied)
        )
        let unknownCommit = try published(
            try await repository.finalizeCalibrationWithHistoricalFrames(unknown.request)
        )
        let unknownFrame = try #require(
            try await repository.historicalObservationFrame(
                sequence: unknownCommit.logical.sequence
            )
        )
        #expect(
            unknownFrame.nodes.first { $0.endpoint.subjectID.rawValue == "child" }?
                .endpoint.state == .unknown(.permissionDenied)
        )

        let present = try await prepareHistoricalLedgerRun(
            repository: repository,
            child: .present(logical: 40, allocated: 32),
            observedAtMilliseconds: 2_000_000_100_000
        )
        _ = try await repository.finalizeCalibrationWithHistoricalFrames(present.request)

        let absent = try await prepareHistoricalLedgerRun(
            repository: repository,
            child: .absent,
            observedAtMilliseconds: 2_000_000_200_000
        )
        let root = try #require(
            absent.request.observation.nodes.first { $0.subjectID.rawValue == "root" }
        )
        let incompleteRoot = try historicalLedgerNode(
            subject: "root",
            parent: nil,
            location: root.locationID.rawValue,
            path: root.path,
            displayName: root.displayName,
            state: root.state,
            childrenCoverage: .partial,
            observedAtMilliseconds: root.observedAt.millisecondsSince1970
        )
        let nodes = absent.request.observation.nodes.map {
            $0.subjectID.rawValue == "root" ? incompleteRoot : $0
        }
        #expect(
            throws: HistoricalFindingPersistenceModelError.invalidObservationModel(
                .absenceParentEvidenceIncomplete
            )
        ) {
            _ = try HistoricalPairedObservationCandidate(
                rootSubjectID: absent.request.observation.rootSubjectID,
                rootPath: absent.request.observation.rootPath,
                nodes: nodes,
                scopeID: absent.request.observation.scopeID,
                volumeID: absent.request.observation.volumeID,
                mountGenerationID: absent.request.observation.mountGenerationID,
                coverageEpochID: absent.request.observation.coverageEpochID,
                pathSemanticsVersion: absent.request.observation.pathSemanticsVersion,
                measurementSemanticsVersion: absent.request.observation.measurementSemanticsVersion
            )
        }
        try await repository.discardCalibration(
            absent.runID,
            disposition: .cancelled,
            report: nil
        )
        try await repository.close()
    }

    @Test("Candidate and staged present rows must match byte-for-byte")
    func candidateMustMatchStaging() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try repository(for: fixture)
        let prepared = try await prepareHistoricalLedgerRun(repository: repository)

        var nodes = prepared.request.observation.nodes
        let rootIndex = try #require(
            nodes.firstIndex { $0.subjectID.rawValue == "root" }
        )
        nodes[rootIndex] = try historicalLedgerNode(
            subject: "root",
            parent: nil,
            location: "location-root",
            path: "/Fixtures",
            displayName: "Fixtures",
            state: .present(
                logicalBytes: ByteCount(101),
                allocatedBytes: ByteCount(80),
                measurementCoverage: .complete
            ),
            childrenCoverage: .complete,
            observedAtMilliseconds: 2_000_000_000_000
        )
        let mismatched = try HistoricalPairedObservationCandidate(
            rootSubjectID: prepared.request.observation.rootSubjectID,
            rootPath: prepared.request.observation.rootPath,
            nodes: nodes,
            scopeID: prepared.request.observation.scopeID,
            volumeID: prepared.request.observation.volumeID,
            mountGenerationID: prepared.request.observation.mountGenerationID,
            coverageEpochID: prepared.request.observation.coverageEpochID,
            pathSemanticsVersion: prepared.request.observation.pathSemanticsVersion,
            measurementSemanticsVersion: prepared.request.observation.measurementSemanticsVersion
        )
        let request = try HistoricalCalibrationFinalizationRequest(
            runID: prepared.runID,
            report: prepared.report,
            workItem: prepared.workItem,
            streamID: prepared.streamID,
            observation: mismatched
        )
        await #expect(throws: SQLiteEventJournalError.historicalCandidateStageMismatch) {
            _ = try await repository.finalizeCalibrationWithHistoricalFrames(request)
        }
        #expect(try fixture.count("historical_observation_batch") == 0)
        #expect(
            try await repository.pendingDirtyWork(for: prepared.streamID, limit: 1).count == 1
        )

        let forgedWork = DirtyRegionWorkItem(
            region: try DirtyRegion(
                path: prepared.workItem.region.path,
                reasons: [.removed, .requiresCalibration],
                maximumCursor: prepared.workItem.region.maximumCursor
            ),
            revision: prepared.workItem.revision
        )
        let forgedRequest = try HistoricalCalibrationFinalizationRequest(
            runID: prepared.runID,
            report: prepared.report,
            workItem: forgedWork,
            streamID: prepared.streamID,
            observation: prepared.request.observation
        )
        await #expect(
            throws: SQLiteEventJournalError.scanRunContextMismatch(
                prepared.runID.rawValue
            )
        ) {
            _ = try await repository.finalizeCalibrationWithHistoricalFrames(forgedRequest)
        }
        try await repository.close()
    }

    @Test("Every historical insertion failure rolls the graph and current publication back", arguments: HistoricalLedgerFailureCase.all)
    func failuresRollback(testCase: HistoricalLedgerFailureCase) async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try SQLiteEventJournalRepository(
            databaseURL: fixture.databaseURL,
            failurePoint: testCase.failurePoint,
            now: { Date(timeIntervalSince1970: 2_000_000_010) },
            historicalStoreGenerationProvider: { Array(repeating: 0x11, count: 16) }
        )
        let prepared = try await prepareHistoricalLedgerRun(repository: repository)

        await #expect(throws: SQLiteEventJournalError.injectedFailure) {
            _ = try await repository.finalizeCalibrationWithHistoricalFrames(prepared.request)
        }
        for table in [
            "historical_observation_batch",
            "historical_observation_node",
            "historical_metric_endpoint",
            "historical_observation_frame_commit",
            "historical_calibration_receipt",
            "historical_projection_work",
        ] {
            #expect(try fixture.count(table) == 0)
        }
        #expect(try fixture.count("directory_history_sample") == 0)
        #expect(try fixture.count("scan_node_stage") == 2)
        #expect(
            try fixture.rows(
                "SELECT state FROM scan_run WHERE id='\(prepared.runID.rawValue)'"
            ) == [["running"]]
        )
        #expect(
            try await repository.currentDirectoryAggregates(for: prepared.streamID).isEmpty
        )
        #expect(
            try await repository.pendingDirtyWork(for: prepared.streamID, limit: 1).count == 1
        )
        try await repository.close()
    }

    @Test("Unknown and non-running run IDs fail through the typed scan-run boundary")
    func invalidRunStateFailsTyped() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try repository(for: fixture)
        let prepared = try await prepareHistoricalLedgerRun(repository: repository)
        let unknownRun = try CalibrationRunID("123e4567-e89b-12d3-a456-426614174999")
        let unknownRequest = try HistoricalCalibrationFinalizationRequest(
            runID: unknownRun,
            report: prepared.report,
            workItem: prepared.workItem,
            streamID: prepared.streamID,
            observation: prepared.request.observation
        )
        await #expect(
            throws: SQLiteEventJournalError.scanRunNotFound(unknownRun.rawValue)
        ) {
            _ = try await repository.finalizeCalibrationWithHistoricalFrames(unknownRequest)
        }

        try await repository.discardCalibration(
            prepared.runID,
            disposition: .cancelled,
            report: nil
        )
        await #expect(
            throws: SQLiteEventJournalError.scanRunNotRunning(prepared.runID.rawValue)
        ) {
            _ = try await repository.finalizeCalibrationWithHistoricalFrames(prepared.request)
        }
        try await repository.close()
    }

    @Test("Commit success followed by response loss is idempotent before and after reopen")
    func responseLossIsIdempotent() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        var repository = try SQLiteEventJournalRepository(
            databaseURL: fixture.databaseURL,
            failurePoint: .afterCalibrationCommitBeforeReturningReceipt,
            now: { Date(timeIntervalSince1970: 2_000_000_010) },
            historicalStoreGenerationProvider: { Array(repeating: 0x22, count: 16) }
        )
        let prepared = try await prepareHistoricalLedgerRun(repository: repository)
        await #expect(throws: SQLiteEventJournalError.injectedFailure) {
            _ = try await repository.finalizeCalibrationWithHistoricalFrames(prepared.request)
        }

        let immediate = try published(
            try await repository.finalizeCalibrationWithHistoricalFrames(prepared.request)
        )
        #expect(immediate.disposition == .alreadyCommitted)
        try await repository.close()

        repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        let reopened = try published(
            try await repository.finalizeCalibrationWithHistoricalFrames(prepared.request)
        )
        #expect(reopened == immediate)
        #expect(try fixture.count("historical_calibration_receipt") == 1)
        #expect(try fixture.count("historical_observation_batch") == 1)

        let changed = try HistoricalCalibrationFinalizationRequest(
            runID: prepared.runID,
            report: CalibrationReport(
                coverage: .complete,
                entriesVisited: prepared.report.entriesVisited + 1,
                directoriesStaged: prepared.report.directoriesStaged,
                gaps: []
            ),
            workItem: prepared.workItem,
            streamID: prepared.streamID,
            observation: prepared.request.observation
        )
        await #expect(throws: SQLiteEventJournalError.historicalImmutableRequestConflict) {
            _ = try await repository.finalizeCalibrationWithHistoricalFrames(changed)
        }
        try await repository.close()
    }

    @Test("Every accepted terminal retry field is part of the immutable request")
    func terminalRetryMatrix() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try repository(for: fixture)
        let prepared = try await prepareHistoricalLedgerRun(repository: repository)
        _ = try await repository.finalizeCalibrationWithHistoricalFrames(prepared.request)

        let changedStream = try HistoricalCalibrationFinalizationRequest(
            runID: prepared.runID,
            report: prepared.report,
            workItem: prepared.workItem,
            streamID: EventStreamID("changed-stream"),
            observation: prepared.request.observation
        )
        let changedRegion = try DirtyRegion(
            path: DirtyRegionPath("/Fixtures/Changed"),
            reasons: prepared.workItem.region.reasons,
            maximumCursor: prepared.workItem.region.maximumCursor
        )
        let changedWorkPath = try HistoricalCalibrationFinalizationRequest(
            runID: prepared.runID,
            report: prepared.report,
            workItem: DirtyRegionWorkItem(
                region: changedRegion,
                revision: prepared.workItem.revision
            ),
            streamID: prepared.streamID,
            observation: prepared.request.observation
        )
        let changedRevision = try HistoricalCalibrationFinalizationRequest(
            runID: prepared.runID,
            report: prepared.report,
            workItem: DirtyRegionWorkItem(
                region: prepared.workItem.region,
                revision: DirtyRegionRevision(prepared.workItem.revision.rawValue + 1)
            ),
            streamID: prepared.streamID,
            observation: prepared.request.observation
        )
        let changedReasons = try HistoricalCalibrationFinalizationRequest(
            runID: prepared.runID,
            report: prepared.report,
            workItem: DirtyRegionWorkItem(
                region: DirtyRegion(
                    path: prepared.workItem.region.path,
                    reasons: [.removed, .requiresCalibration],
                    maximumCursor: prepared.workItem.region.maximumCursor
                ),
                revision: prepared.workItem.revision
            ),
            streamID: prepared.streamID,
            observation: prepared.request.observation
        )
        let changedCursor = try HistoricalCalibrationFinalizationRequest(
            runID: prepared.runID,
            report: prepared.report,
            workItem: DirtyRegionWorkItem(
                region: DirtyRegion(
                    path: prepared.workItem.region.path,
                    reasons: prepared.workItem.region.reasons,
                    maximumCursor: EventJournalCursor(
                        (prepared.workItem.region.maximumCursor?.rawValue ?? 0) + 1
                    )
                ),
                revision: prepared.workItem.revision
            ),
            streamID: prepared.streamID,
            observation: prepared.request.observation
        )
        let changedReport = try HistoricalCalibrationFinalizationRequest(
            runID: prepared.runID,
            report: CalibrationReport(
                coverage: .complete,
                entriesVisited: prepared.report.entriesVisited + 1,
                directoriesStaged: prepared.report.directoriesStaged,
                gaps: []
            ),
            workItem: prepared.workItem,
            streamID: prepared.streamID,
            observation: prepared.request.observation
        )
        let changedCandidate = try HistoricalCalibrationFinalizationRequest(
            runID: prepared.runID,
            report: prepared.report,
            workItem: prepared.workItem,
            streamID: prepared.streamID,
            observation: try HistoricalPairedObservationCandidate(
                rootSubjectID: prepared.request.observation.rootSubjectID,
                rootPath: prepared.request.observation.rootPath,
                nodes: prepared.request.observation.nodes,
                scopeID: prepared.request.observation.scopeID,
                volumeID: prepared.request.observation.volumeID,
                mountGenerationID: prepared.request.observation.mountGenerationID,
                coverageEpochID: prepared.request.observation.coverageEpochID,
                pathSemanticsVersion: prepared.request.observation.pathSemanticsVersion,
                measurementSemanticsVersion: ObservationSemanticsVersion(2)
            )
        )

        for changed in [
            changedStream, changedWorkPath, changedRevision, changedReasons,
            changedCursor, changedReport, changedCandidate,
        ] {
            await #expect(throws: SQLiteEventJournalError.historicalImmutableRequestConflict) {
                _ = try await repository.finalizeCalibrationWithHistoricalFrames(changed)
            }
        }
        try await repository.close()
    }

    @Test("Retention is anchored to the earliest node observation, not finalization time")
    func retentionUsesEarliestObservation() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try repository(for: fixture)
        let prepared = try await prepareHistoricalLedgerRun(repository: repository)
        _ = try await repository.finalizeCalibrationWithHistoricalFrames(prepared.request)

        #expect(
            try fixture.rows(
                "SELECT retention_anchor_ms,expires_at_ms FROM historical_observation_frame_commit ORDER BY sequence"
            ) == [
                ["2000000000000", "2002592000000"],
                ["2000000000000", "2002592000000"],
            ]
        )
        try await repository.close()
    }

    @Test("A superseded run has one durable terminal receipt and no frame")
    func supersededRunIsIdempotent() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try repository(for: fixture)
        let prepared = try await prepareHistoricalLedgerRun(repository: repository)
        let newer = try DirtyRegion(
            path: prepared.workItem.region.path,
            reasons: [.metadataChanged, .requiresCalibration],
            maximumCursor: EventJournalCursor(9_999)
        )
        try await repository.markDirty(streamID: prepared.streamID, regions: [newer])

        #expect(
            try await repository.finalizeCalibrationWithHistoricalFrames(prepared.request)
                == .superseded
        )
        #expect(
            try await repository.finalizeCalibrationWithHistoricalFrames(prepared.request)
                == .superseded
        )
        let changedReport = try HistoricalCalibrationFinalizationRequest(
            runID: prepared.runID,
            report: CalibrationReport(
                coverage: .complete,
                entriesVisited: prepared.report.entriesVisited + 1,
                directoriesStaged: prepared.report.directoriesStaged,
                gaps: []
            ),
            workItem: prepared.workItem,
            streamID: prepared.streamID,
            observation: prepared.request.observation
        )
        await #expect(throws: SQLiteEventJournalError.historicalImmutableRequestConflict) {
            _ = try await repository.finalizeCalibrationWithHistoricalFrames(changedReport)
        }
        #expect(try fixture.count("historical_calibration_receipt") == 1)
        #expect(try fixture.count("historical_observation_batch") == 0)
        try await repository.close()
    }

    @Test("Expired observations fail before dirty work is consumed")
    func expiredCandidateFailsClosed() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try SQLiteEventJournalRepository(
            databaseURL: fixture.databaseURL,
            failurePoint: nil,
            now: { Date(timeIntervalSince1970: 2_100_000_000) },
            historicalStoreGenerationProvider: { Array(repeating: 0x33, count: 16) }
        )
        let prepared = try await prepareHistoricalLedgerRun(repository: repository)
        await #expect(throws: SQLiteEventJournalError.historicalCandidateExpired) {
            _ = try await repository.finalizeCalibrationWithHistoricalFrames(prepared.request)
        }
        #expect(
            try await repository.pendingDirtyWork(for: prepared.streamID, limit: 1).count == 1
        )
        #expect(try fixture.count("historical_observation_batch") == 0)
        try await repository.close()
    }

    @Test("Endpoint identity is store-local and wall-clock rollback does not reorder sequences")
    func endpointIdentityAndWallClock() async throws {
        let firstFixture = try HistoricalLedgerTestFixture()
        let secondFixture = try HistoricalLedgerTestFixture()
        defer {
            firstFixture.remove()
            secondFixture.remove()
        }
        let clock = Mutex(Date(timeIntervalSince1970: 2_000_000_010))
        let firstRepository = try SQLiteEventJournalRepository(
            databaseURL: firstFixture.databaseURL,
            failurePoint: nil,
            now: { clock.withLock { $0 } },
            historicalStoreGenerationProvider: { Array(repeating: 0x44, count: 16) }
        )
        let secondRepository = try SQLiteEventJournalRepository(
            databaseURL: secondFixture.databaseURL,
            failurePoint: nil,
            now: { Date(timeIntervalSince1970: 1) },
            historicalStoreGenerationProvider: { Array(repeating: 0x55, count: 16) }
        )
        let firstPrepared = try await prepareHistoricalLedgerRun(
            repository: firstRepository
        )
        let first = try published(
            try await firstRepository.finalizeCalibrationWithHistoricalFrames(
                firstPrepared.request
            )
        )
        clock.withLock { value in
            value = Date(timeIntervalSince1970: 2_000_000_005)
        }
        let rollbackPrepared = try await prepareHistoricalLedgerRun(
            repository: firstRepository,
            logicalRootBytes: 120,
            allocatedRootBytes: 96,
            observedAtMilliseconds: 2_000_000_100_000
        )
        let rollback = try published(
            try await firstRepository.finalizeCalibrationWithHistoricalFrames(
                rollbackPrepared.request
            )
        )
        #expect(rollback.logical.sequence.rawValue > first.allocated.sequence.rawValue)
        #expect(
            try firstFixture.rows(
                "SELECT committed_at_ms FROM historical_observation_frame_commit ORDER BY sequence"
            ) == [
                ["2000000010000"], ["2000000010000"],
                ["2000000005000"], ["2000000005000"],
            ]
        )
        let secondPrepared = try await prepareHistoricalLedgerRun(repository: secondRepository)
        let second = try published(
            try await secondRepository.finalizeCalibrationWithHistoricalFrames(
                secondPrepared.request
            )
        )
        #expect(first.logical.sequence == second.logical.sequence)
        #expect(first.logical.rootEndpointID != second.logical.rootEndpointID)
        try await firstRepository.close()
        try await secondRepository.close()
    }

    @Test("Legacy finalization remains source-compatible and creates no v11 evidence")
    func legacyFinalizationDoesNotCreateHistoricalEvidence() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try repository(for: fixture)
        let prepared = try await prepareHistoricalLedgerRun(repository: repository)

        #expect(
            try await repository.finalizeCalibration(
                prepared.runID,
                report: prepared.report,
                workItem: prepared.workItem,
                streamID: prepared.streamID
            )
        )
        #expect(try fixture.count("historical_observation_batch") == 0)
        #expect(try fixture.count("historical_calibration_receipt") == 0)
        try await repository.close()
    }

    private func repository(
        for fixture: HistoricalLedgerTestFixture
    ) throws -> SQLiteEventJournalRepository {
        try SQLiteEventJournalRepository(
            databaseURL: fixture.databaseURL,
            failurePoint: nil,
            now: { Date(timeIntervalSince1970: 2_000_000_010) },
            historicalStoreGenerationProvider: { Array(repeating: 0x11, count: 16) }
        )
    }

    private func published(
        _ outcome: HistoricalCalibrationFinalizationOutcome
    ) throws -> HistoricalCalibrationCommit {
        guard case let .published(commit) = outcome else {
            throw HistoricalLedgerTestError.expectedPublished
        }
        return commit
    }
}

struct HistoricalLedgerFailureCase: Sendable, CustomTestStringConvertible {
    let name: String
    let failurePoint: SQLiteEventJournalTestFailurePoint

    static let all: [Self] = [
        Self(name: "dictionaries", failurePoint: .afterHistoricalDictionaries),
        Self(name: "batch", failurePoint: .afterHistoricalBatch),
        Self(name: "nodes", failurePoint: .afterHistoricalNodes),
        Self(name: "logical endpoints", failurePoint: .afterHistoricalLogicalEndpoints),
        Self(name: "logical marker", failurePoint: .afterHistoricalLogicalMarker),
        Self(name: "before work", failurePoint: .beforeHistoricalProjectionWork),
    ]

    var testDescription: String { name }
}

private enum HistoricalLedgerTestError: Error {
    case expectedPublished
}
