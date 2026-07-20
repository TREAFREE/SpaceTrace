import Foundation
import Testing
import SpaceTraceApplication
import SpaceTraceDomain
import SQLite3
@testable import SpaceTracePersistence

struct SQLiteEventJournalRepositoryTests {
    @Test("A migrated empty database has no journal state")
    func emptyDatabase() async throws {
        try await withRepository { repository in
            let streamID = try EventStreamID("volume-a:generation-1")

            #expect(try await repository.checkpoint(for: streamID) == nil)
            #expect(try await repository.dirtyRegions(for: streamID).isEmpty)
        }
    }

    @Test("Schema version one journal state migrates to revisioned work")
    func migratesVersionOne() async throws {
        let fixture = try TemporaryDatabase()
        try createVersionOneFixture(at: fixture.databaseURL)
        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        let streamID = try EventStreamID("volume-v1:generation-1")

        #expect(try await repository.checkpoint(for: streamID) == EventJournalCursor(42))
        let workItem = try #require(
            try await repository.pendingDirtyWork(for: streamID, limit: 1).first
        )
        let initialRevision = try DirtyRegionRevision(1)
        #expect(workItem.region.path.rawValue == "/Users/example/Documents")
        #expect(workItem.region.maximumCursor == EventJournalCursor(42))
        #expect(workItem.revision == initialRevision)

        try await repository.close()
        fixture.remove()
    }

    @Test("Schema version three migrates to persistent scope mount generations")
    func migratesVersionThreeMountState() async throws {
        let fixture = try TemporaryDatabase()
        try createVersionThreeMountFixture(at: fixture.databaseURL)
        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        let scopeID = try WatchedScopeID("scope-migrated")
        let generationID = try MountGenerationID("mount-generation-migrated")
        let volumeUUID = try #require(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        )
        let evidence = try VolumeMountEvidence(
            mountPath: DirtyRegionPath("/Volumes/Migrated"),
            volumeUUID: volumeUUID
        )

        let transition = try await repository.activateScopeMount(
            scopeID: scopeID,
            evidence: evidence,
            proposedGenerationID: generationID
        )

        #expect(transition.reason == .firstMount)
        #expect(try await repository.scopeMountGeneration(for: scopeID) == transition.current)

        try await repository.close()
        fixture.remove()
    }

    @Test("Schema version four migrates to security-scoped bookmark storage")
    func migratesVersionFourBookmarkStorage() async throws {
        let fixture = try TemporaryDatabase()
        try createVersionFourFixture(at: fixture.databaseURL)
        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        let bookmark = try makeWatchedScopeBookmark(
            scopeID: "scope-migrated-bookmark",
            root: "/Volumes/Migrated/Selected",
            byte: 0x44
        )

        try await repository.upsertWatchedScopeBookmark(bookmark)

        #expect(try await repository.watchedScopeBookmarks() == [bookmark])
        try await repository.close()
        fixture.remove()
    }

    @Test("Committed baseline metadata and multiple roots round-trip by scope")
    func persistsAuthorizedBaselineSnapshot() async throws {
        try await withRepository { repository in
            let timestamp = Date(timeIntervalSince1970: 1_750_000_000)
            let firstScopeID = try WatchedScopeID("scope-baseline-first")
            let secondScopeID = try WatchedScopeID("scope-baseline-second")
            let snapshot = try makeAuthorizedBaselineSnapshot(
                id: "baseline-round-trip",
                timestamp: timestamp,
                roots: [
                    (firstScopeID, "/Users/example/First", "stream-first", 1_024),
                    (secondScopeID, "/Users/example/Second", "stream-second", 2_048),
                ]
            )

            try await repository.saveAuthorizedBaseline(snapshot)

            #expect(
                try await repository.latestAuthorizedBaseline(for: firstScopeID) == snapshot
            )
            #expect(
                try await repository.latestAuthorizedBaseline(for: secondScopeID) == snapshot
            )
        }
    }

    @Test("Restart discards interrupted staging but preserves durable dirty work")
    func recoversInterruptedCalibrationRun() async throws {
        let fixture = try TemporaryDatabase()
        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        let streamID = try EventStreamID("volume-restart:generation-1")
        let batch = try makeBatch(
            streamID: streamID,
            path: "/Users/example/Interrupted",
            reasons: .requiresCalibration,
            cursor: 9
        )
        try await repository.commit(batch)
        let workItem = try #require(
            try await repository.pendingDirtyWork(for: streamID, limit: 1).first
        )
        let runID = try await repository.beginCalibration(
            CalibrationRequest(streamID: streamID, workItem: workItem)
        )
        try await repository.stageCalibration(
            [
                makeAggregate(
                    path: "/Users/example/Interrupted",
                    logical: 100,
                    allocated: 200,
                    descendants: 1
                ),
            ],
            in: runID
        )
        try await repository.close()

        let reopened = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        #expect(try await reopened.pendingDirtyWork(for: streamID, limit: 10) == [workItem])
        try await reopened.close()

        #expect(
            try readSQLiteText(
                from: fixture.databaseURL,
                sql: "SELECT state FROM scan_run WHERE id = ?1",
                argument: runID.rawValue
            ) == "failed"
        )
        #expect(
            try readSQLiteCount(
                from: fixture.databaseURL,
                sql: "SELECT COUNT(*) FROM scan_node_stage WHERE scan_run_id = ?1",
                argument: runID.rawValue
            ) == 0
        )
        fixture.remove()
    }

    @Test("Bookmark writes replace atomically by scope and support explicit removal")
    func persistsAndRemovesBookmarks() async throws {
        try await withRepository { repository in
            let first = try makeWatchedScopeBookmark(
                scopeID: "scope-bookmark",
                root: "/Volumes/Projects/First",
                byte: 0x01
            )
            let replacement = try makeWatchedScopeBookmark(
                scopeID: "scope-bookmark",
                root: "/Volumes/Projects/Replacement",
                byte: 0x02
            )

            try await repository.upsertWatchedScopeBookmark(first)
            try await repository.upsertWatchedScopeBookmark(replacement)
            #expect(try await repository.watchedScopeBookmarks() == [replacement])

            try await repository.removeWatchedScopeBookmark(for: replacement.scopeID)
            #expect(try await repository.watchedScopeBookmarks().isEmpty)
        }
    }

    @Test("Duplicate mount callbacks persist one active generation")
    func deduplicatesPersistentMountActivation() async throws {
        try await withRepository { repository in
            let scopeID = try WatchedScopeID("scope-primary")
            let firstGeneration = try MountGenerationID("mount-generation-1")
            let ignoredGeneration = try MountGenerationID("mount-generation-ignored")
            let volumeUUID = try #require(
                UUID(uuidString: "11111111-2222-3333-4444-555555555555")
            )
            let evidence = try VolumeMountEvidence(
                mountPath: DirtyRegionPath("/Volumes/Projects"),
                volumeUUID: volumeUUID
            )

            let first = try await repository.activateScopeMount(
                scopeID: scopeID,
                evidence: evidence,
                proposedGenerationID: firstGeneration
            )
            let duplicate = try await repository.activateScopeMount(
                scopeID: scopeID,
                evidence: evidence,
                proposedGenerationID: ignoredGeneration
            )

            #expect(first.current.generationID == firstGeneration)
            #expect(duplicate.reason == .duplicateNotification)
            #expect(duplicate.current.generationID == firstGeneration)
            #expect(try await repository.scopeMountGeneration(for: scopeID) == duplicate.current)
        }
    }

    @Test("A process restart closes every previously active mount generation")
    func closesActiveGenerationsWhenRepositoryReopens() async throws {
        let fixture = try TemporaryDatabase()
        let scopeID = try WatchedScopeID("scope-restart")
        let firstGeneration = try MountGenerationID("mount-generation-before-restart")
        let nextGeneration = try MountGenerationID("mount-generation-after-restart")
        let volumeUUID = try #require(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        )
        let evidence = try VolumeMountEvidence(
            mountPath: DirtyRegionPath("/Volumes/Projects"),
            volumeUUID: volumeUUID
        )

        let originalRepository = try SQLiteEventJournalRepository(
            databaseURL: fixture.databaseURL
        )
        _ = try await originalRepository.activateScopeMount(
            scopeID: scopeID,
            evidence: evidence,
            proposedGenerationID: firstGeneration
        )
        try await originalRepository.close()

        let reopenedRepository = try SQLiteEventJournalRepository(
            databaseURL: fixture.databaseURL
        )
        #expect(try await reopenedRepository.scopeMountGeneration(for: scopeID)?.isActive == false)
        let transition = try await reopenedRepository.activateScopeMount(
            scopeID: scopeID,
            evidence: evidence,
            proposedGenerationID: nextGeneration
        )
        #expect(transition.reason == .remountedSameVolume)
        #expect(transition.current.generationID == nextGeneration)

        try await reopenedRepository.close()
        fixture.remove()
    }

    @Test("A late unmount callback cannot deactivate a replacement generation")
    func conditionallyDeactivatesExpectedGeneration() async throws {
        try await withRepository { repository in
            let scopeID = try WatchedScopeID("scope-replacement")
            let firstGeneration = try MountGenerationID("mount-generation-1")
            let replacementGeneration = try MountGenerationID("mount-generation-2")
            let volumeA = try #require(
                UUID(uuidString: "11111111-2222-3333-4444-555555555555")
            )
            let volumeB = try #require(
                UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
            )
            let mountPath = try DirtyRegionPath("/Volumes/Projects")

            _ = try await repository.activateScopeMount(
                scopeID: scopeID,
                evidence: VolumeMountEvidence(mountPath: mountPath, volumeUUID: volumeA),
                proposedGenerationID: firstGeneration
            )
            let replacement = try await repository.activateScopeMount(
                scopeID: scopeID,
                evidence: VolumeMountEvidence(mountPath: mountPath, volumeUUID: volumeB),
                proposedGenerationID: replacementGeneration
            )

            #expect(replacement.reason == .replacementVolume)
            #expect(
                try await repository.deactivateScopeMount(
                    scopeID: scopeID,
                    matching: firstGeneration
                ) == false
            )
            #expect(try await repository.scopeMountGeneration(for: scopeID)?.isActive == true)
            #expect(
                try await repository.deactivateScopeMount(
                    scopeID: scopeID,
                    matching: replacementGeneration
                )
            )
            #expect(try await repository.scopeMountGeneration(for: scopeID)?.isActive == false)
        }
    }

    @Test("A batch makes dirty work and its checkpoint visible atomically")
    func atomicCommit() async throws {
        try await withRepository { repository in
            let streamID = try EventStreamID("volume-a:generation-1")
            let expectedRegion = try makeRegion(
                path: "/Users/example/Library/Caches",
                reasons: [.contentModified],
                cursor: 42
            )
            let batch = try EventJournalBatch(
                streamID: streamID,
                checkpoint: EventJournalCursor(42),
                dirtyRegions: [expectedRegion]
            )

            try await repository.commit(batch)

            #expect(try await repository.checkpoint(for: streamID) == EventJournalCursor(42))
            #expect(try await repository.dirtyRegions(for: streamID) == [expectedRegion])
        }
    }

    @Test("Repeated work for one path unions reasons and retains the maximum cursor")
    func coalescesSamePath() async throws {
        try await withRepository { repository in
            let streamID = try EventStreamID("volume-a:generation-1")
            let path = "/Users/example/Documents"
            try await repository.commit(
                makeBatch(
                    streamID: streamID,
                    path: path,
                    reasons: [.created],
                    cursor: 5
                )
            )
            try await repository.commit(
                makeBatch(
                    streamID: streamID,
                    path: path,
                    reasons: [.renamed, .metadataChanged],
                    cursor: 9
                )
            )

            let regions = try await repository.dirtyRegions(for: streamID)
            let region = try #require(regions.first)
            let expectedPath = try DirtyRegionPath(path)
            #expect(regions.count == 1)
            #expect(region.path == expectedPath)
            #expect(region.reasons == [.created, .renamed, .metadataChanged])
            #expect(region.maximumCursor == EventJournalCursor(9))
            #expect(try await repository.checkpoint(for: streamID) == EventJournalCursor(9))
        }
    }

    @Test("Cursor-free calibration work does not create or advance a checkpoint")
    func marksDirtyWithoutCursor() async throws {
        try await withRepository { repository in
            let streamID = try EventStreamID("volume-root:generation-1")
            let region = try DirtyRegion(
                path: DirtyRegionPath("/Users/example"),
                reasons: [.rootChanged, .requiresCalibration],
                maximumCursor: nil
            )
            try await repository.markDirty(streamID: streamID, regions: [region])

            #expect(try await repository.checkpoint(for: streamID) == nil)
            #expect(try await repository.dirtyRegions(for: streamID) == [region])
        }
    }

    @Test("Checkpoint invalidation atomically clears every dirty cursor and advances revisions")
    func invalidatesCheckpointWithRecoveryWork() async throws {
        try await withRepository { repository in
            let streamID = try EventStreamID("volume-wrap:generation-1")
            try await repository.commit(
                makeBatch(
                    streamID: streamID,
                    path: "/Users/example/Documents",
                    reasons: [.contentModified],
                    cursor: 42
                )
            )
            let original = try #require(
                try await repository.pendingDirtyWork(for: streamID, limit: 1).first
            )
            let recovery = try DirtyRegion(
                path: DirtyRegionPath("/Users/example"),
                reasons: [.droppedEvents, .requiresCalibration],
                maximumCursor: nil
            )

            try await repository.invalidateCheckpointAndMarkDirty(
                streamID: streamID,
                regions: [recovery]
            )

            #expect(try await repository.checkpoint(for: streamID) == nil)
            let current = try #require(
                try await repository.pendingDirtyWork(for: streamID, limit: 1).first
            )
            #expect(current.region.path.rawValue == "/Users/example")
            #expect(current.region.maximumCursor == nil)
            #expect(current.region.reasons.contains(.droppedEvents))
            #expect(current.revision > original.revision)
        }
    }

    @Test("Checkpoint invalidation rolls recovery work back on failure")
    func checkpointInvalidationRollsBack() async throws {
        try await withRepository(
            failurePoint: .afterRecoveryWorkBeforeCheckpointInvalidation
        ) { repository in
            let streamID = try EventStreamID("volume-wrap-failure:generation-1")
            try await repository.commit(
                makeBatch(
                    streamID: streamID,
                    path: "/Users/example/Documents",
                    reasons: [.contentModified],
                    cursor: 42
                )
            )
            let original = try #require(
                try await repository.pendingDirtyWork(for: streamID, limit: 1).first
            )
            let recovery = try DirtyRegion(
                path: DirtyRegionPath("/Users/example"),
                reasons: [.droppedEvents, .requiresCalibration],
                maximumCursor: nil
            )

            await #expect(throws: SQLiteEventJournalError.injectedFailure) {
                try await repository.invalidateCheckpointAndMarkDirty(
                    streamID: streamID,
                    regions: [recovery]
                )
            }

            #expect(try await repository.checkpoint(for: streamID) == EventJournalCursor(42))
            #expect(
                try await repository.pendingDirtyWork(for: streamID, limit: 1).first
                    == original
            )
        }
    }

    @Test("An ancestor region absorbs durable descendant work")
    func coalescesOverlappingPaths() async throws {
        try await withRepository { repository in
            let streamID = try EventStreamID("volume-overlap:generation-1")
            try await repository.commit(
                makeBatch(
                    streamID: streamID,
                    path: "/Users/example/Documents/Project",
                    reasons: [.created],
                    cursor: 3
                )
            )
            try await repository.commit(
                makeBatch(
                    streamID: streamID,
                    path: "/Users/example/Documents",
                    reasons: [.mustScanSubdirectories],
                    cursor: 4
                )
            )

            let region = try #require(
                try await repository.dirtyRegions(for: streamID).first
            )
            #expect(try await repository.dirtyRegions(for: streamID).count == 1)
            #expect(region.path.rawValue == "/Users/example/Documents")
            #expect(region.reasons == [.created, .mustScanSubdirectories])
            #expect(region.maximumCursor == EventJournalCursor(4))
        }
    }

    @Test("A stale scan token cannot clear work updated during calibration")
    func conditionalResolutionPreservesNewerWork() async throws {
        try await withRepository { repository in
            let streamID = try EventStreamID("volume-race:generation-1")
            try await repository.commit(
                makeBatch(
                    streamID: streamID,
                    path: "/Users/example/Documents",
                    reasons: [.contentModified],
                    cursor: 1
                )
            )
            let stale = try #require(
                try await repository.pendingDirtyWork(for: streamID, limit: 1).first
            )
            try await repository.markDirty(
                streamID: streamID,
                regions: [
                    try DirtyRegion(
                        path: stale.region.path,
                        reasons: [.removed],
                        maximumCursor: nil
                    ),
                ]
            )

            #expect(try await repository.resolve(stale, for: streamID) == false)
            let current = try #require(
                try await repository.pendingDirtyWork(for: streamID, limit: 1).first
            )
            #expect(current.revision > stale.revision)
            #expect(current.region.reasons == [.contentModified, .removed])
            #expect(try await repository.resolve(current, for: streamID))
            #expect(try await repository.dirtyRegions(for: streamID).isEmpty)
        }
    }

    @Test("Complete staged aggregates publish atomically and clear matching dirty work")
    func finalizesCompleteCalibration() async throws {
        try await withRepository { repository in
            let streamID = try EventStreamID("volume-scan:generation-1")
            let root = "/Users/example/Documents"
            try await repository.commit(
                makeBatch(streamID: streamID, path: root, reasons: [.contentModified], cursor: 1)
            )
            let workItem = try #require(
                try await repository.pendingDirtyWork(for: streamID, limit: 1).first
            )
            let request = CalibrationRequest(streamID: streamID, workItem: workItem)
            let runID = try await repository.beginCalibration(request)
            let aggregates = try [
                makeAggregate(path: root, logical: 30, allocated: 24, descendants: 2),
                makeAggregate(path: root + "/Project", logical: 20, allocated: 16, descendants: 1),
            ]
            try await repository.stageCalibration(aggregates, in: runID)

            let finalized = try await repository.finalizeCalibration(
                runID,
                report: completeReport(entries: 3, directories: 2),
                workItem: workItem,
                streamID: streamID
            )

            #expect(finalized)
            #expect(try await repository.dirtyRegions(for: streamID).isEmpty)
            #expect(try await repository.currentDirectoryAggregates(for: streamID) == aggregates)
        }
    }

    @Test("Partial staging is discarded and cannot replace current truth")
    func discardsPartialCalibration() async throws {
        try await withRepository { repository in
            let streamID = try EventStreamID("volume-partial:generation-1")
            let root = try DirtyRegionPath("/Users/example/Documents")
            try await repository.commit(
                makeBatch(streamID: streamID, path: root.rawValue, reasons: [.created], cursor: 1)
            )
            let workItem = try #require(
                try await repository.pendingDirtyWork(for: streamID, limit: 1).first
            )
            let runID = try await repository.beginCalibration(
                CalibrationRequest(streamID: streamID, workItem: workItem)
            )
            try await repository.stageCalibration(
                [
                    try DirectoryMetadataAggregate(
                        path: root,
                        logicalBytes: try ByteCount(10),
                        allocatedBytes: nil,
                        descendantCount: 1,
                        coverage: .partial
                    ),
                ],
                in: runID
            )
            let report = try CalibrationReport(
                coverage: .partial,
                entriesVisited: 2,
                directoriesStaged: 1,
                gaps: [CalibrationGap(path: root, reason: .permissionDenied)]
            )
            try await repository.discardCalibration(
                runID,
                disposition: .partial,
                report: report
            )

            #expect(try await repository.currentDirectoryAggregates(for: streamID).isEmpty)
            #expect(try await repository.dirtyRegions(for: streamID).count == 1)
        }
    }

    @Test("A stale calibration publishes nothing when its dirty revision changed")
    func staleCalibrationDoesNotPublish() async throws {
        try await withRepository { repository in
            let streamID = try EventStreamID("volume-stale-scan:generation-1")
            let root = "/Users/example/Documents"
            try await repository.commit(
                makeBatch(streamID: streamID, path: root, reasons: [.created], cursor: 1)
            )
            let staleWork = try #require(
                try await repository.pendingDirtyWork(for: streamID, limit: 1).first
            )
            let runID = try await repository.beginCalibration(
                CalibrationRequest(streamID: streamID, workItem: staleWork)
            )
            try await repository.stageCalibration(
                [try makeAggregate(path: root, logical: 10, allocated: 8, descendants: 1)],
                in: runID
            )
            try await repository.markDirty(
                streamID: streamID,
                regions: [
                    try DirtyRegion(
                        path: DirtyRegionPath(root),
                        reasons: [.removed],
                        maximumCursor: nil
                    ),
                ]
            )

            let finalized = try await repository.finalizeCalibration(
                runID,
                report: completeReport(entries: 2, directories: 1),
                workItem: staleWork,
                streamID: streamID
            )
            #expect(finalized == false)
            #expect(try await repository.currentDirectoryAggregates(for: streamID).isEmpty)
            #expect(try await repository.dirtyRegions(for: streamID).count == 1)
        }
    }

    @Test("Only a complete rescan marks previously known descendants missing")
    func completeRescanMarksMissingDirectoryDeleted() async throws {
        try await withRepository { repository in
            let streamID = try EventStreamID("volume-delete:generation-1")
            let root = "/Users/example/Documents"
            try await repository.commit(
                makeBatch(streamID: streamID, path: root, reasons: [.created], cursor: 1)
            )
            var workItem = try #require(
                try await repository.pendingDirtyWork(for: streamID, limit: 1).first
            )
            var runID = try await repository.beginCalibration(
                CalibrationRequest(streamID: streamID, workItem: workItem)
            )
            try await repository.stageCalibration(
                [
                    try makeAggregate(path: root, logical: 20, allocated: 16, descendants: 1),
                    try makeAggregate(path: root + "/Old", logical: 10, allocated: 8, descendants: 0),
                ],
                in: runID
            )
            _ = try await repository.finalizeCalibration(
                runID,
                report: completeReport(entries: 2, directories: 2),
                workItem: workItem,
                streamID: streamID
            )

            try await repository.markDirty(
                streamID: streamID,
                regions: [
                    try DirtyRegion(
                        path: DirtyRegionPath(root),
                        reasons: [.removed],
                        maximumCursor: nil
                    ),
                ]
            )
            workItem = try #require(
                try await repository.pendingDirtyWork(for: streamID, limit: 1).first
            )
            runID = try await repository.beginCalibration(
                CalibrationRequest(streamID: streamID, workItem: workItem)
            )
            let replacement = try makeAggregate(
                path: root,
                logical: 10,
                allocated: 8,
                descendants: 0
            )
            try await repository.stageCalibration([replacement], in: runID)
            _ = try await repository.finalizeCalibration(
                runID,
                report: completeReport(entries: 1, directories: 1),
                workItem: workItem,
                streamID: streamID
            )

            #expect(
                try await repository.currentDirectoryAggregates(for: streamID)
                    == [replacement]
            )
        }
    }

    @Test("A checkpoint regression is rejected without persisting its dirty work")
    func rejectsCursorRegression() async throws {
        try await withRepository { repository in
            let streamID = try EventStreamID("volume-a:generation-1")
            let originalBatch = try makeBatch(
                streamID: streamID,
                path: "/Users/example/original",
                reasons: [.created],
                cursor: 10
            )
            let regressingBatch = try makeBatch(
                streamID: streamID,
                path: "/Users/example/regressing",
                reasons: [.removed],
                cursor: 9
            )
            try await repository.commit(originalBatch)

            do {
                try await repository.commit(regressingBatch)
                Issue.record("Expected a cursor regression error.")
            } catch let error as SQLiteEventJournalError {
                #expect(error == .cursorRegression(stored: 10, attempted: 9))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(try await repository.checkpoint(for: streamID) == EventJournalCursor(10))
            let regions = try await repository.dirtyRegions(for: streamID)
            #expect(regions.map(\.path.rawValue) == ["/Users/example/original"])
        }
    }

    @Test("The full UInt64 cursor range round-trips through its BLOB encoding")
    func maximumCursorRoundTrip() async throws {
        try await withRepository { repository in
            let streamID = try EventStreamID("volume-max:generation-1")
            let batch = try makeBatch(
                streamID: streamID,
                path: "/Users/example/max",
                reasons: [.mustScanSubdirectories],
                cursor: .max
            )

            try await repository.commit(batch)

            #expect(
                try await repository.checkpoint(for: streamID)
                    == EventJournalCursor(.max)
            )
            let region = try #require(
                try await repository.dirtyRegions(for: streamID).first
            )
            #expect(region.maximumCursor == EventJournalCursor(.max))
        }
    }

    @Test("Concurrent callers are serialized by the repository actor")
    func serializesConcurrentCalls() async throws {
        try await withRepository { repository in
            let streamID = try EventStreamID("volume-concurrent:generation-1")
            let batches = try (0..<32).map { index in
                try makeBatch(
                    streamID: streamID,
                    path: "/Users/example/concurrent/\(index)",
                    reasons: [.contentModified],
                    regionCursor: UInt64(index),
                    checkpoint: 100
                )
            }

            try await withThrowingTaskGroup(of: Void.self) { group in
                for batch in batches {
                    group.addTask {
                        try await repository.commit(batch)
                    }
                }
                try await group.waitForAll()
            }

            #expect(try await repository.checkpoint(for: streamID) == EventJournalCursor(100))
            #expect(try await repository.dirtyRegions(for: streamID).count == batches.count)
        }
    }

    @Test("An injected failure between dirty work and checkpoint rolls back both")
    func injectedFailureRollsBackTransaction() async throws {
        try await withRepository(failurePoint: .afterDirtyRegionsBeforeCheckpoint) { repository in
            let streamID = try EventStreamID("volume-failure:generation-1")
            let batch = try makeBatch(
                streamID: streamID,
                path: "/Users/example/rollback",
                reasons: [.requiresCalibration],
                cursor: 71
            )

            do {
                try await repository.commit(batch)
                Issue.record("Expected the injected transaction failure.")
            } catch let error as SQLiteEventJournalError {
                #expect(error == .injectedFailure)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(try await repository.checkpoint(for: streamID) == nil)
            #expect(try await repository.dirtyRegions(for: streamID).isEmpty)
        }
    }

    @Test(
        "Dirty region paths reject empty, relative, and non-normalized values",
        arguments: ["", "relative/path", "/trailing/", "/double//slash", "/dot/./path", "/parent/../path"]
    )
    func rejectsInvalidPaths(path: String) {
        #expect(throws: EventJournalModelError.invalidDirtyRegionPath(path)) {
            try DirtyRegionPath(path)
        }
    }

    @Test("Operations after explicit close report a typed error")
    func closedRepositoryReportsTypedError() async throws {
        let fixture = try TemporaryDatabase()
        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        let streamID = try EventStreamID("volume-closed:generation-1")
        try await repository.close()

        do {
            _ = try await repository.checkpoint(for: streamID)
            Issue.record("Expected a database-closed error.")
        } catch let error as SQLiteEventJournalError {
            #expect(error == .databaseClosed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        fixture.remove()
    }
}

private struct TemporaryDatabase {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpaceTracePersistenceTests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent("SpaceTrace.sqlite", isDirectory: false)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func withRepository<Result>(
    failurePoint: SQLiteEventJournalTestFailurePoint? = nil,
    operation: (SQLiteEventJournalRepository) async throws -> Result
) async throws -> Result {
    let fixture = try TemporaryDatabase()
    let repository = try SQLiteEventJournalRepository(
        databaseURL: fixture.databaseURL,
        failurePoint: failurePoint
    )

    do {
        let result = try await operation(repository)
        try await repository.close()
        fixture.remove()
        return result
    } catch {
        try? await repository.close()
        fixture.remove()
        throw error
    }
}

private func makeRegion(
    path: String,
    reasons: DirtyRegionReason,
    cursor: UInt64
) throws -> DirtyRegion {
    try DirtyRegion(
        path: DirtyRegionPath(path),
        reasons: reasons,
        maximumCursor: EventJournalCursor(cursor)
    )
}

private func makeAggregate(
    path: String,
    logical: Int64,
    allocated: Int64,
    descendants: Int64
) throws -> DirectoryMetadataAggregate {
    try DirectoryMetadataAggregate(
        path: DirtyRegionPath(path),
        logicalBytes: ByteCount(logical),
        allocatedBytes: ByteCount(allocated),
        descendantCount: descendants,
        coverage: .complete
    )
}

private func completeReport(
    entries: Int64,
    directories: Int64
) throws -> CalibrationReport {
    try CalibrationReport(
        coverage: .complete,
        entriesVisited: entries,
        directoriesStaged: directories,
        gaps: []
    )
}

private func makeBatch(
    streamID: EventStreamID,
    path: String,
    reasons: DirtyRegionReason,
    cursor: UInt64
) throws -> EventJournalBatch {
    try makeBatch(
        streamID: streamID,
        path: path,
        reasons: reasons,
        regionCursor: cursor,
        checkpoint: cursor
    )
}

private func createVersionOneFixture(at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
        throw MigrationFixtureError.openFailed
    }
    defer { sqlite3_close(database) }

    let sql = """
        CREATE TABLE schema_migration (
            version INTEGER PRIMARY KEY,
            applied_at_ms INTEGER NOT NULL,
            checksum TEXT NOT NULL
        );
        CREATE TABLE event_checkpoint (
            stream_id TEXT PRIMARY KEY NOT NULL,
            cursor_be BLOB NOT NULL CHECK(length(cursor_be) = 8)
        ) WITHOUT ROWID;
        CREATE TABLE dirty_region (
            stream_id TEXT NOT NULL,
            path TEXT NOT NULL,
            reasons INTEGER NOT NULL CHECK(reasons != 0),
            maximum_cursor_be BLOB NOT NULL CHECK(length(maximum_cursor_be) = 8),
            PRIMARY KEY(stream_id, path),
            FOREIGN KEY(stream_id) REFERENCES event_checkpoint(stream_id)
        ) WITHOUT ROWID;
        INSERT INTO schema_migration(version, applied_at_ms, checksum)
        VALUES(1, 0, 'event-journal-v1-big-endian-cursor');
        INSERT INTO event_checkpoint(stream_id, cursor_be)
        VALUES('volume-v1:generation-1', X'000000000000002A');
        INSERT INTO dirty_region(stream_id, path, reasons, maximum_cursor_be)
        VALUES('volume-v1:generation-1', '/Users/example/Documents', 8,
            X'000000000000002A');
        PRAGMA user_version = 1;
        """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw MigrationFixtureError.createFailed
    }
}

private func createVersionThreeMountFixture(at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
        throw MigrationFixtureError.openFailed
    }
    defer { sqlite3_close(database) }

    let sql = """
        CREATE TABLE schema_migration (
            version INTEGER PRIMARY KEY,
            applied_at_ms INTEGER NOT NULL,
            checksum TEXT NOT NULL
        );
        \(minimalCalibrationTablesSQL)
        INSERT INTO schema_migration(version, applied_at_ms, checksum)
        VALUES(3, 0, 'calibration-v3-staging-finalization');
        PRAGMA user_version = 3;
        """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw MigrationFixtureError.createFailed
    }
}

private func createVersionFourFixture(at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
        throw MigrationFixtureError.openFailed
    }
    defer { sqlite3_close(database) }

    let sql = """
        CREATE TABLE schema_migration (
            version INTEGER PRIMARY KEY,
            applied_at_ms INTEGER NOT NULL,
            checksum TEXT NOT NULL
        );
        CREATE TABLE scope_mount_generation (
            scope_id TEXT PRIMARY KEY NOT NULL,
            mount_generation TEXT NOT NULL,
            mount_path TEXT NOT NULL,
            volume_uuid TEXT,
            is_active INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
        ) WITHOUT ROWID;
        \(minimalCalibrationTablesSQL)
        INSERT INTO schema_migration(version, applied_at_ms, checksum)
        VALUES(4, 0, 'scope-mount-generation-v4');
        PRAGMA user_version = 4;
        """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw MigrationFixtureError.createFailed
    }
}

private let minimalCalibrationTablesSQL = """
    CREATE TABLE scan_run (
        id TEXT PRIMARY KEY NOT NULL,
        stream_id TEXT NOT NULL,
        region_path TEXT NOT NULL,
        dirty_revision_be BLOB NOT NULL CHECK(length(dirty_revision_be) = 8),
        state TEXT NOT NULL CHECK(state IN (
            'running', 'completed', 'partial', 'cancelled',
            'failed', 'superseded'
        )),
        coverage TEXT CHECK(coverage IN ('complete', 'partial')),
        entries_seen INTEGER NOT NULL DEFAULT 0,
        directories_staged INTEGER NOT NULL DEFAULT 0,
        started_at_ms INTEGER NOT NULL,
        finished_at_ms INTEGER
    ) WITHOUT ROWID;
    CREATE TABLE scan_node_stage (
        scan_run_id TEXT NOT NULL REFERENCES scan_run(id) ON DELETE CASCADE,
        path TEXT NOT NULL,
        logical_bytes INTEGER,
        allocated_bytes INTEGER,
        descendant_count INTEGER NOT NULL,
        coverage TEXT NOT NULL,
        PRIMARY KEY(scan_run_id, path)
    ) WITHOUT ROWID;
    """

private func makeAuthorizedBaselineSnapshot(
    id: String,
    timestamp: Date,
    roots: [(WatchedScopeID, String, String, Int64)]
) throws -> AuthorizedBaselineSnapshot {
    let rootSnapshots = try roots.map { scopeID, path, streamID, logicalBytes in
        try AuthorizedBaselineRootSnapshot(
            context: AuthorizedBaselineScanContext(
                scopeID: scopeID,
                root: DirtyRegionPath(path),
                streamID: EventStreamID(streamID)
            ),
            logicalBytes: ByteCount(logicalBytes),
            allocatedBytes: ByteCount(logicalBytes * 2),
            descendantCount: 3,
            entriesVisited: 4,
            directoriesObserved: 2
        )
    }
    return try AuthorizedBaselineSnapshot(
        id: AuthorizedBaselineID(id),
        startedAt: timestamp,
        committedAt: timestamp.addingTimeInterval(1),
        build: AuthorizedBaselineBuildMetadata(
            appVersion: "0.1.0 (1)",
            schemaVersion: SQLiteEventJournalRepository.currentSchemaVersion
        ),
        startupVolume: StartupVolumeCapacitySnapshot(
            observedAt: timestamp,
            volumeUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555"),
            totalBytes: ByteCount(10_000),
            availableBytes: ByteCount(4_000),
            availableForImportantUsageBytes: nil
        ),
        roots: rootSnapshots
    )
}

private func readSQLiteText(
    from databaseURL: URL,
    sql: String,
    argument: String
) throws -> String? {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        throw MigrationFixtureError.openFailed
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw MigrationFixtureError.createFailed
    }
    defer { sqlite3_finalize(statement) }
    try argument.withCString { value in
        guard sqlite3_bind_text(statement, 1, value, -1, nil) == SQLITE_OK else {
            throw MigrationFixtureError.createFailed
        }
    }
    guard sqlite3_step(statement) == SQLITE_ROW,
          let text = sqlite3_column_text(statement, 0) else {
        return nil
    }
    return String(cString: text)
}

private func readSQLiteCount(
    from databaseURL: URL,
    sql: String,
    argument: String
) throws -> Int64 {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        throw MigrationFixtureError.openFailed
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw MigrationFixtureError.createFailed
    }
    defer { sqlite3_finalize(statement) }
    try argument.withCString { value in
        guard sqlite3_bind_text(statement, 1, value, -1, nil) == SQLITE_OK else {
            throw MigrationFixtureError.createFailed
        }
    }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw MigrationFixtureError.createFailed
    }
    return sqlite3_column_int64(statement, 0)
}

private enum MigrationFixtureError: Error {
    case openFailed
    case createFailed
}

private func makeWatchedScopeBookmark(
    scopeID: String,
    root: String,
    byte: UInt8
) throws -> WatchedScopeBookmark {
    try WatchedScopeBookmark(
        scopeID: WatchedScopeID(scopeID),
        bookmarkData: Data([byte]),
        expectedRoot: DirtyRegionPath(root),
        expectedVolumeUUID: UUID(
            uuidString: "11111111-2222-3333-4444-555555555555"
        )!
    )
}

private func makeBatch(
    streamID: EventStreamID,
    path: String,
    reasons: DirtyRegionReason,
    regionCursor: UInt64,
    checkpoint: UInt64
) throws -> EventJournalBatch {
    try EventJournalBatch(
        streamID: streamID,
        checkpoint: EventJournalCursor(checkpoint),
        dirtyRegions: [
            makeRegion(path: path, reasons: reasons, cursor: regionCursor),
        ]
    )
}
