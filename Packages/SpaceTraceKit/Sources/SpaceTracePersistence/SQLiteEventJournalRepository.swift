import Foundation
import SQLite3
import SpaceTraceApplication
import SpaceTraceDomain
import Synchronization

/// A dependency-free SQLite prototype for ADR-004. The actor is the sole
/// owner of the connection and serializes every transaction and query.
public actor SQLiteEventJournalRepository: EventJournalRepository, ScopeMountGenerationRepository, WatchedScopeBookmarkRepository, AuthorizedBaselineSnapshotRepository, DirectoryHistoryRepository {
    public static let currentSchemaVersion = 8
    private static let schemaVersion = Int32(currentSchemaVersion)

    /// `Mutex` makes the non-Sendable C handle safe to release from the
    /// actor's nonisolated deinitializer. All operational access remains
    /// serialized by the actor itself.
    private let connection: Mutex<OpaquePointer?>
    private var injectedFailurePoint: SQLiteEventJournalTestFailurePoint?
    private let now: @Sendable () -> Date

    public init(databaseURL: URL) throws {
        try self.init(databaseURL: databaseURL, failurePoint: nil)
    }

    init(
        databaseURL: URL,
        failurePoint: SQLiteEventJournalTestFailurePoint?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard databaseURL.isFileURL, databaseURL.path.isEmpty == false else {
            throw SQLiteEventJournalError.invalidDatabaseLocation
        }

        try SQLiteArtifactValidator.validateBeforeOpen(databaseURL: databaseURL)

        var openedDatabase: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(databaseURL.path, &openedDatabase, flags, nil)

        guard openResult == SQLITE_OK, let openedDatabase else {
            let message = Self.errorMessage(from: openedDatabase)
            if let openedDatabase {
                _ = sqlite3_close_v2(openedDatabase)
            }
            throw SQLiteEventJournalError.openFailed(code: openResult, message: message)
        }

        let migrationBackupURL: URL?
        do {
            migrationBackupURL = try Self.configureAndMigrate(
                openedDatabase,
                databaseURL: databaseURL,
                failurePoint: failurePoint
            )
        } catch {
            _ = sqlite3_close_v2(openedDatabase)
            throw error
        }

        connection = Mutex(openedDatabase)
        injectedFailurePoint = failurePoint
        self.now = now
        if let migrationBackupURL {
            try? FileManager.default.removeItem(at: migrationBackupURL)
        }
    }

    deinit {
        connection.withLock { database in
            if let database {
                _ = sqlite3_close_v2(database)
            }
            database = nil
        }
    }

    /// Atomically coalesces dirty regions and then monotonically advances the
    /// stream checkpoint. Any error rolls the complete batch back.
    public func commit(_ batch: EventJournalBatch) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION", operation: "begin event-journal transaction")

        do {
            if let storedCheckpoint = try readCheckpoint(for: batch.streamID),
               batch.checkpoint < storedCheckpoint {
                throw SQLiteEventJournalError.cursorRegression(
                    stored: storedCheckpoint.rawValue,
                    attempted: batch.checkpoint.rawValue
                )
            }

            try merge(regions: batch.dirtyRegions, streamID: batch.streamID)

            try failIfRequested(at: .afterDirtyRegionsBeforeCheckpoint)
            try upsert(checkpoint: batch.checkpoint, streamID: batch.streamID)
            try execute("COMMIT TRANSACTION", operation: "commit event-journal transaction")
        } catch {
            try rollback(after: error)
        }
    }

    /// Persists calibration work without moving the journal checkpoint. This
    /// is required for stream-wide sentinels that do not carry a usable ID.
    public func markDirty(streamID: EventStreamID, regions: [DirtyRegion]) throws {
        guard regions.isEmpty == false else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION", operation: "begin dirty-region transaction")
        do {
            try merge(regions: regions, streamID: streamID)
            try execute("COMMIT TRANSACTION", operation: "commit dirty-region transaction")
        } catch {
            try rollback(after: error)
        }
    }

    public func invalidateCheckpointAndMarkDirty(
        streamID: EventStreamID,
        regions: [DirtyRegion]
    ) throws {
        guard regions.isEmpty == false else {
            throw EventJournalModelError.emptyBatch
        }
        try execute(
            "BEGIN IMMEDIATE TRANSACTION",
            operation: "begin checkpoint-invalidation transaction"
        )
        do {
            try clearDirtyRegionCursors(for: streamID)
            try merge(regions: regions, streamID: streamID)
            try failIfRequested(at: .afterRecoveryWorkBeforeCheckpointInvalidation)
            try deleteCheckpoint(for: streamID)
            try execute(
                "COMMIT TRANSACTION",
                operation: "commit checkpoint-invalidation transaction"
            )
        } catch {
            try rollback(after: error)
        }
    }

    public func checkpoint(for streamID: EventStreamID) throws -> EventJournalCursor? {
        try readCheckpoint(for: streamID)
    }

    public func dirtyRegions(for streamID: EventStreamID) throws -> [DirtyRegion] {
        let sql = """
            SELECT path, reasons, maximum_cursor_be
            FROM dirty_region
            WHERE stream_id = ?1
            ORDER BY path ASC
            """

        return try withStatement(sql, operation: "read dirty regions") { statement in
            try streamID.rawValue.withCString { streamCString in
                try check(
                    sqlite3_bind_text(statement, 1, streamCString, -1, nil),
                    operation: "bind dirty-region stream ID"
                )

                var regions: [DirtyRegion] = []
                while true {
                    let result = sqlite3_step(statement)
                    switch result {
                    case SQLITE_ROW:
                        let path = try readText(
                            from: statement,
                            column: 0,
                            field: "dirty_region.path"
                        )
                        let reasonsRawValue = UInt64(
                            bitPattern: sqlite3_column_int64(statement, 1)
                        )
                        let cursor = try readOptionalCursor(
                            from: statement,
                            column: 2,
                            field: "dirty_region.maximum_cursor_be"
                        )

                        do {
                            let region = try DirtyRegion(
                                path: DirtyRegionPath(path),
                                reasons: DirtyRegionReason(rawValue: reasonsRawValue),
                                maximumCursor: cursor
                            )
                            regions.append(region)
                        } catch {
                            throw SQLiteEventJournalError.corruptStoredValue(
                                field: "dirty_region"
                            )
                        }
                    case SQLITE_DONE:
                        return regions
                    default:
                        throw sqliteFailure(
                            operation: "step dirty-region query",
                            code: result
                        )
                    }
                }
            }
        }
    }

    public func activateScopeMount(
        scopeID: WatchedScopeID,
        evidence: VolumeMountEvidence,
        proposedGenerationID: MountGenerationID
    ) throws -> ScopeMountActivation {
        try execute(
            "BEGIN IMMEDIATE TRANSACTION",
            operation: "begin scope-mount activation"
        )
        do {
            let previous = try readScopeMountGeneration(for: scopeID)
            let transition = ScopeMountGenerationStateMachine.activate(
                previous: previous,
                scopeID: scopeID,
                evidence: evidence,
                proposedGenerationID: proposedGenerationID
            )
            try upsertScopeMountGeneration(transition.current)
            try execute(
                "COMMIT TRANSACTION",
                operation: "commit scope-mount activation"
            )
            return transition
        } catch {
            try rollback(after: error)
        }
    }

    public func deactivateScopeMount(
        scopeID: WatchedScopeID,
        matching generationID: MountGenerationID
    ) throws -> Bool {
        let sql = """
            UPDATE scope_mount_generation
            SET is_active = 0,
                updated_at_ms = CAST(strftime('%s', 'now') AS INTEGER) * 1000
            WHERE scope_id = ?1 AND mount_generation = ?2 AND is_active = 1
            """
        return try withStatement(sql, operation: "deactivate scope mount") { statement in
            try scopeID.rawValue.withCString { scopeCString in
                try generationID.rawValue.withCString { generationCString in
                    try check(
                        sqlite3_bind_text(statement, 1, scopeCString, -1, nil),
                        operation: "bind scope ID for deactivation"
                    )
                    try check(
                        sqlite3_bind_text(statement, 2, generationCString, -1, nil),
                        operation: "bind mount generation for deactivation"
                    )
                    try stepExpectingDone(statement, operation: "update inactive scope mount")
                    return sqlite3_changes(try databaseHandle()) == 1
                }
            }
        }
    }

    public func scopeMountGeneration(
        for scopeID: WatchedScopeID
    ) throws -> ScopeMountGeneration? {
        try readScopeMountGeneration(for: scopeID)
    }

    public func watchedScopeBookmarks() throws -> [WatchedScopeBookmark] {
        let sql = """
            SELECT scope_id, bookmark, expected_root, expected_volume_uuid
            FROM watched_scope_bookmark
            ORDER BY scope_id ASC
            """
        return try withStatement(sql, operation: "read watched-scope bookmarks") { statement in
            var bookmarks: [WatchedScopeBookmark] = []
            while true {
                let result = sqlite3_step(statement)
                switch result {
                case SQLITE_ROW:
                    let scopeID = try readText(
                        from: statement,
                        column: 0,
                        field: "watched_scope_bookmark.scope_id"
                    )
                    let data = try readData(
                        from: statement,
                        column: 1,
                        field: "watched_scope_bookmark.bookmark"
                    )
                    let expectedRoot = try readText(
                        from: statement,
                        column: 2,
                        field: "watched_scope_bookmark.expected_root"
                    )
                    let expectedVolumeUUID = try readText(
                        from: statement,
                        column: 3,
                        field: "watched_scope_bookmark.expected_volume_uuid"
                    )
                    do {
                        guard let volumeUUID = UUID(uuidString: expectedVolumeUUID) else {
                            throw SQLiteEventJournalError.corruptStoredValue(
                                field: "watched_scope_bookmark.expected_volume_uuid"
                            )
                        }
                        bookmarks.append(
                            try WatchedScopeBookmark(
                                scopeID: WatchedScopeID(scopeID),
                                bookmarkData: data,
                                expectedRoot: DirtyRegionPath(expectedRoot),
                                expectedVolumeUUID: volumeUUID
                            )
                        )
                    } catch let error as SQLiteEventJournalError {
                        throw error
                    } catch {
                        throw SQLiteEventJournalError.corruptStoredValue(
                            field: "watched_scope_bookmark"
                        )
                    }
                case SQLITE_DONE:
                    return bookmarks
                default:
                    throw sqliteFailure(
                        operation: "step watched-scope bookmark query",
                        code: result
                    )
                }
            }
        }
    }

    public func upsertWatchedScopeBookmark(_ bookmark: WatchedScopeBookmark) throws {
        let sql = """
            INSERT INTO watched_scope_bookmark(
                scope_id, bookmark, expected_root, expected_volume_uuid,
                created_at_ms, updated_at_ms
            ) VALUES(
                ?1, ?2, ?3, ?4,
                CAST(strftime('%s', 'now') AS INTEGER) * 1000,
                CAST(strftime('%s', 'now') AS INTEGER) * 1000
            )
            ON CONFLICT(scope_id) DO UPDATE SET
                bookmark = excluded.bookmark,
                expected_root = excluded.expected_root,
                expected_volume_uuid = excluded.expected_volume_uuid,
                updated_at_ms = excluded.updated_at_ms
            """
        try withStatement(sql, operation: "upsert watched-scope bookmark") { statement in
            try bookmark.scopeID.rawValue.withCString { scopeCString in
                try bookmark.expectedRoot.rawValue.withCString { rootCString in
                    try bookmark.expectedVolumeUUID.uuidString.lowercased().withCString {
                        volumeCString in
                        try bookmark.bookmarkData.withUnsafeBytes { bookmarkBuffer in
                            try check(
                                sqlite3_bind_text(statement, 1, scopeCString, -1, nil),
                                operation: "bind bookmark scope ID"
                            )
                            try check(
                                sqlite3_bind_blob(
                                    statement,
                                    2,
                                    bookmarkBuffer.baseAddress,
                                    Int32(bookmarkBuffer.count),
                                    nil
                                ),
                                operation: "bind bookmark data"
                            )
                            try check(
                                sqlite3_bind_text(statement, 3, rootCString, -1, nil),
                                operation: "bind bookmark expected root"
                            )
                            try check(
                                sqlite3_bind_text(statement, 4, volumeCString, -1, nil),
                                operation: "bind bookmark expected volume UUID"
                            )
                            try stepExpectingDone(
                                statement,
                                operation: "write watched-scope bookmark"
                            )
                        }
                    }
                }
            }
        }
    }

    public func removeWatchedScopeBookmark(for scopeID: WatchedScopeID) throws {
        let sql = "DELETE FROM watched_scope_bookmark WHERE scope_id = ?1"
        try withStatement(sql, operation: "remove watched-scope bookmark") { statement in
            try scopeID.rawValue.withCString { scopeCString in
                try check(
                    sqlite3_bind_text(statement, 1, scopeCString, -1, nil),
                    operation: "bind removed bookmark scope ID"
                )
                try stepExpectingDone(statement, operation: "delete watched-scope bookmark")
            }
        }
    }

    public func pendingDirtyWork(
        for streamID: EventStreamID,
        limit: Int
    ) throws -> [DirtyRegionWorkItem] {
        guard limit > 0 else { return [] }
        let sql = """
            SELECT path, reasons, maximum_cursor_be, revision_be
            FROM dirty_region
            WHERE stream_id = ?1
            ORDER BY path ASC
            LIMIT ?2
            """
        return try withStatement(sql, operation: "read pending dirty work") { statement in
            try streamID.rawValue.withCString { streamCString in
                try check(
                    sqlite3_bind_text(statement, 1, streamCString, -1, nil),
                    operation: "bind pending-work stream ID"
                )
                try check(
                    sqlite3_bind_int64(statement, 2, Int64(limit)),
                    operation: "bind pending-work limit"
                )
                var work: [DirtyRegionWorkItem] = []
                while true {
                    let result = sqlite3_step(statement)
                    switch result {
                    case SQLITE_ROW:
                        let path = try readText(
                            from: statement,
                            column: 0,
                            field: "dirty_region.path"
                        )
                        let reasons = DirtyRegionReason(
                            rawValue: UInt64(bitPattern: sqlite3_column_int64(statement, 1))
                        )
                        let cursor = try readOptionalCursor(
                            from: statement,
                            column: 2,
                            field: "dirty_region.maximum_cursor_be"
                        )
                        let revisionValue = try readUInt64(
                            from: statement,
                            column: 3,
                            field: "dirty_region.revision_be"
                        )
                        do {
                            let region = try DirtyRegion(
                                path: DirtyRegionPath(path),
                                reasons: reasons,
                                maximumCursor: cursor
                            )
                            work.append(
                                DirtyRegionWorkItem(
                                    region: region,
                                    revision: try DirtyRegionRevision(revisionValue)
                                )
                            )
                        } catch {
                            throw SQLiteEventJournalError.corruptStoredValue(
                                field: "dirty_region"
                            )
                        }
                    case SQLITE_DONE:
                        return work
                    default:
                        throw sqliteFailure(
                            operation: "step pending-work query",
                            code: result
                        )
                    }
                }
            }
        }
    }

    public func resolve(
        _ workItem: DirtyRegionWorkItem,
        for streamID: EventStreamID
    ) throws -> Bool {
        let sql = """
            DELETE FROM dirty_region
            WHERE stream_id = ?1 AND path = ?2 AND revision_be = ?3
            """
        let revisionBytes = Self.encode(workItem.revision.rawValue)
        return try withStatement(sql, operation: "resolve dirty work") { statement in
            try streamID.rawValue.withCString { streamCString in
                try workItem.region.path.rawValue.withCString { pathCString in
                    try revisionBytes.withUnsafeBytes { revisionBuffer in
                        try check(
                            sqlite3_bind_text(statement, 1, streamCString, -1, nil),
                            operation: "bind resolve stream ID"
                        )
                        try check(
                            sqlite3_bind_text(statement, 2, pathCString, -1, nil),
                            operation: "bind resolve path"
                        )
                        try check(
                            sqlite3_bind_blob(
                                statement,
                                3,
                                revisionBuffer.baseAddress,
                                Int32(revisionBuffer.count),
                                nil
                            ),
                            operation: "bind resolve revision"
                        )
                        try stepExpectingDone(statement, operation: "delete resolved work")
                        return sqlite3_changes(try databaseHandle()) == 1
                    }
                }
            }
        }
    }

    public func beginCalibration(_ request: CalibrationRequest) throws -> CalibrationRunID {
        let runID = try CalibrationRunID(UUID().uuidString.lowercased())
        let revisionBytes = Self.encode(request.workItem.revision.rawValue)
        let startedAt = Self.milliseconds(now())
        let sql = """
            INSERT INTO scan_run(
                id, stream_id, region_path, dirty_revision_be, state, started_at_ms
            ) VALUES(?1, ?2, ?3, ?4, 'running', ?5)
            """
        try withStatement(sql, operation: "begin calibration run") { statement in
            try runID.rawValue.withCString { runCString in
                try request.streamID.rawValue.withCString { streamCString in
                    try request.workItem.region.path.rawValue.withCString { pathCString in
                        try revisionBytes.withUnsafeBytes { revisionBuffer in
                            try check(sqlite3_bind_text(statement, 1, runCString, -1, nil), operation: "bind scan run ID")
                            try check(sqlite3_bind_text(statement, 2, streamCString, -1, nil), operation: "bind scan stream ID")
                            try check(sqlite3_bind_text(statement, 3, pathCString, -1, nil), operation: "bind scan region")
                            try check(
                                sqlite3_bind_blob(statement, 4, revisionBuffer.baseAddress, Int32(revisionBuffer.count), nil),
                                operation: "bind scan revision"
                            )
                            try check(sqlite3_bind_int64(statement, 5, startedAt), operation: "bind scan start time")
                            try stepExpectingDone(statement, operation: "insert calibration run")
                        }
                    }
                }
            }
        }
        return runID
    }

    public func stageCalibration(
        _ aggregates: [DirectoryMetadataAggregate],
        in runID: CalibrationRunID
    ) throws {
        guard aggregates.isEmpty == false else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION", operation: "begin calibration staging")
        do {
            let context = try readScanRun(runID)
            guard context.state == "running" else {
                throw SQLiteEventJournalError.scanRunNotRunning(runID.rawValue)
            }
            for aggregate in aggregates {
                guard Self.contains(aggregate.path.rawValue, in: context.regionPath.rawValue) else {
                    throw SQLiteEventJournalError.aggregateOutsideScanRegion(
                        aggregate.path.rawValue
                    )
                }
                try upsertStagedAggregate(aggregate, runID: runID)
            }
            try execute("COMMIT TRANSACTION", operation: "commit calibration staging")
        } catch {
            try rollback(after: error)
        }
    }

    public func finalizeCalibration(
        _ runID: CalibrationRunID,
        report: CalibrationReport,
        workItem: DirtyRegionWorkItem,
        streamID: EventStreamID
    ) throws -> Bool {
        guard report.coverage == .complete else {
            throw SQLiteEventJournalError.incompleteReportCannotFinalize
        }
        try execute("BEGIN IMMEDIATE TRANSACTION", operation: "begin calibration finalization")
        do {
            let context = try readScanRun(runID)
            guard context.state == "running" else {
                throw SQLiteEventJournalError.scanRunNotRunning(runID.rawValue)
            }
            guard context.streamID == streamID,
                  context.regionPath == workItem.region.path,
                  context.revision == workItem.revision else {
                throw SQLiteEventJournalError.scanRunContextMismatch(runID.rawValue)
            }
            let summary = try stagedSummary(runID: runID, root: context.regionPath)
            guard summary.count == report.directoriesStaged,
                  summary.containsRoot,
                  summary.partialCount == 0 else {
                throw SQLiteEventJournalError.stagedDirectoryCountMismatch(
                    expected: report.directoriesStaged,
                    actual: summary.count
                )
            }

            guard try dirtyRevision(
                streamID: streamID,
                path: workItem.region.path
            ) == workItem.revision else {
                try finishScanRun(runID, state: "superseded", report: report)
                try deleteStagedRows(runID)
                try execute("COMMIT TRANSACTION", operation: "commit superseded scan")
                return false
            }

            try markMissingDirectoriesDeleted(
                streamID: streamID,
                region: context.regionPath,
                runID: runID
            )
            try publishStagedDirectories(streamID: streamID, runID: runID)
            try recordDirectoryHistory(
                streamID: streamID,
                runID: runID,
                observedAt: now()
            )
            guard try resolve(workItem, for: streamID) else {
                throw SQLiteEventJournalError.dirtyRevisionChangedDuringFinalization
            }
            try finishScanRun(runID, state: "completed", report: report)
            try deleteStagedRows(runID)
            try execute("COMMIT TRANSACTION", operation: "commit calibration finalization")
            return true
        } catch {
            try rollback(after: error)
        }
    }

    public func discardCalibration(
        _ runID: CalibrationRunID,
        disposition: CalibrationRunDisposition,
        report: CalibrationReport?
    ) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION", operation: "begin calibration discard")
        do {
            let context = try readScanRun(runID)
            guard context.state == "running" else {
                try execute("COMMIT TRANSACTION", operation: "commit idempotent calibration discard")
                return
            }
            try finishScanRun(
                runID,
                state: disposition.rawValue,
                report: report
            )
            try deleteStagedRows(runID)
            try execute("COMMIT TRANSACTION", operation: "commit calibration discard")
        } catch {
            try rollback(after: error)
        }
    }

    public func currentDirectoryAggregates(
        for streamID: EventStreamID
    ) throws -> [DirectoryMetadataAggregate] {
        let sql = """
            SELECT path, logical_bytes, allocated_bytes, descendant_count, coverage
            FROM node_current
            WHERE stream_id = ?1 AND deleted = 0
            ORDER BY path ASC
            """
        return try withStatement(sql, operation: "read current directory aggregates") { statement in
            try streamID.rawValue.withCString { streamCString in
                try check(sqlite3_bind_text(statement, 1, streamCString, -1, nil), operation: "bind aggregate stream ID")
                var aggregates: [DirectoryMetadataAggregate] = []
                while true {
                    let result = sqlite3_step(statement)
                    switch result {
                    case SQLITE_ROW:
                        let path = try readText(from: statement, column: 0, field: "node_current.path")
                        let logical = try readOptionalByteCount(from: statement, column: 1, field: "node_current.logical_bytes")
                        let allocated = try readOptionalByteCount(from: statement, column: 2, field: "node_current.allocated_bytes")
                        let descendantCount = sqlite3_column_int64(statement, 3)
                        let coverageText = try readText(from: statement, column: 4, field: "node_current.coverage")
                        let coverage = try calibrationCoverage(
                            coverageText,
                            field: "node_current.coverage"
                        )
                        do {
                            aggregates.append(
                                try DirectoryMetadataAggregate(
                                    path: DirtyRegionPath(path),
                                    logicalBytes: logical,
                                    allocatedBytes: allocated,
                                    descendantCount: descendantCount,
                                    coverage: coverage
                                )
                            )
                        } catch {
                            throw SQLiteEventJournalError.corruptStoredValue(field: "node_current")
                        }
                    case SQLITE_DONE:
                        return aggregates
                    default:
                        throw sqliteFailure(operation: "step aggregate query", code: result)
                    }
                }
            }
        }
    }

    public func directoryHistory(
        for streamID: EventStreamID,
        path: DirtyRegionPath,
        bucket: DirectoryHistoryBucket,
        from start: Date,
        through end: Date
    ) async throws -> [DirectoryHistorySample] {
        guard start <= end else { return [] }
        let sql = """
            SELECT bucket_start_ms, logical_bytes, allocated_bytes,
                descendant_count, coverage
            FROM directory_history_sample
            WHERE stream_id = ?1 AND path = ?2 AND bucket_kind = ?3
                AND bucket_start_ms BETWEEN ?4 AND ?5
            ORDER BY bucket_start_ms ASC
            """
        return try withStatement(sql, operation: "read directory history") { statement in
            try streamID.rawValue.withCString { streamCString in
                try path.rawValue.withCString { pathCString in
                    try bucket.rawValue.withCString { bucketCString in
                        try check(sqlite3_bind_text(statement, 1, streamCString, -1, nil), operation: "bind history stream")
                        try check(sqlite3_bind_text(statement, 2, pathCString, -1, nil), operation: "bind history path")
                        try check(sqlite3_bind_text(statement, 3, bucketCString, -1, nil), operation: "bind history bucket")
                        try check(sqlite3_bind_int64(statement, 4, Self.milliseconds(start)), operation: "bind history start")
                        try check(sqlite3_bind_int64(statement, 5, Self.milliseconds(end)), operation: "bind history end")
                        var samples: [DirectoryHistorySample] = []
                        while true {
                            switch sqlite3_step(statement) {
                            case SQLITE_ROW:
                                let coverageText = try readText(from: statement, column: 4, field: "directory_history_sample.coverage")
                                samples.append(
                                    DirectoryHistorySample(
                                        streamID: streamID,
                                        path: path,
                                        bucket: bucket,
                                        bucketStart: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0)) / 1_000),
                                        logicalBytes: try readOptionalByteCount(from: statement, column: 1, field: "directory_history_sample.logical_bytes"),
                                        allocatedBytes: try readOptionalByteCount(from: statement, column: 2, field: "directory_history_sample.allocated_bytes"),
                                        descendantCount: try readNonnegativeInt64(from: statement, column: 3, field: "directory_history_sample.descendant_count"),
                                        coverage: try calibrationCoverage(
                                            coverageText,
                                            field: "directory_history_sample.coverage"
                                        )
                                    )
                                )
                            case SQLITE_DONE:
                                return samples
                            default:
                                throw sqliteFailure(
                                    operation: "step directory-history query",
                                    code: sqlite3_errcode(try databaseHandle())
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    public func topDirectoryGrowth(
        for streamID: EventStreamID,
        under root: DirtyRegionPath,
        bucket: DirectoryHistoryBucket = .daily,
        from start: Date,
        through end: Date,
        limit: Int = 100
    ) async throws -> [DirectoryGrowthSample] {
        guard start <= end, limit > 0 else { return [] }
        let sql = """
            SELECT path, SUM(logical_delta) AS delta,
                MIN(bucket_start_ms), MAX(bucket_start_ms),
                CASE
                    WHEN SUM(CASE WHEN coverage = 'complete' THEN 0 ELSE 1 END) = 0
                    THEN 'complete'
                    ELSE 'partial'
                END AS interval_coverage
            FROM directory_history_sample
            WHERE stream_id = ?1 AND bucket_kind = ?2
                AND (
                    ?3 = '/'
                    OR path = ?3
                    OR substr(path, 1, length(?3) + 1) = ?3 || '/'
                )
                AND bucket_start_ms > ?4 AND bucket_start_ms <= ?5
                AND logical_delta IS NOT NULL
            GROUP BY path
            HAVING SUM(logical_delta) > 0
            ORDER BY delta DESC, path ASC
            LIMIT ?6
            """
        return try withStatement(sql, operation: "read top directory growth") { statement in
            try streamID.rawValue.withCString { streamCString in
                try bucket.rawValue.withCString { bucketCString in
                    try root.rawValue.withCString { rootCString in
                        try check(sqlite3_bind_text(statement, 1, streamCString, -1, nil), operation: "bind growth stream")
                        try check(sqlite3_bind_text(statement, 2, bucketCString, -1, nil), operation: "bind growth bucket")
                        try check(sqlite3_bind_text(statement, 3, rootCString, -1, nil), operation: "bind growth root")
                        try check(sqlite3_bind_int64(statement, 4, Self.milliseconds(start)), operation: "bind growth start")
                        try check(sqlite3_bind_int64(statement, 5, Self.milliseconds(end)), operation: "bind growth end")
                        try check(sqlite3_bind_int64(statement, 6, Int64(limit)), operation: "bind growth limit")
                        var results: [DirectoryGrowthSample] = []
                        while true {
                            switch sqlite3_step(statement) {
                            case SQLITE_ROW:
                                let path = try readText(
                                    from: statement,
                                    column: 0,
                                    field: "growth.path"
                                )
                                let coverageText = try readText(
                                    from: statement,
                                    column: 4,
                                    field: "growth.interval_coverage"
                                )
                                results.append(
                                    DirectoryGrowthSample(
                                        streamID: streamID,
                                        path: try DirtyRegionPath(path),
                                        logicalByteDelta: sqlite3_column_int64(
                                            statement,
                                            1
                                        ),
                                        firstObservedAt: Date(
                                            timeIntervalSince1970: TimeInterval(
                                                sqlite3_column_int64(statement, 2)
                                            ) / 1_000
                                        ),
                                        lastObservedAt: Date(
                                            timeIntervalSince1970: TimeInterval(
                                                sqlite3_column_int64(statement, 3)
                                            ) / 1_000
                                        ),
                                        coverage: try calibrationCoverage(
                                            coverageText,
                                            field: "growth.interval_coverage"
                                        )
                                    )
                                )
                            case SQLITE_DONE:
                                return results
                            default:
                                throw sqliteFailure(
                                    operation: "step top-growth query",
                                    code: sqlite3_errcode(try databaseHandle())
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    public func pathFreeCalibrationRequirement(
        for streamID: EventStreamID,
        scopeID: WatchedScopeID
    ) throws -> PathFreeCalibrationRequirement? {
        let sql = """
            SELECT reasons, created_at_ms
            FROM path_free_calibration_requirement
            WHERE stream_id = ?1 AND scope_id = ?2
            """
        return try withStatement(sql, operation: "read path-free calibration requirement") { statement in
            try streamID.rawValue.withCString { streamCString in
                try check(sqlite3_bind_text(statement, 1, streamCString, -1, nil), operation: "bind path-free stream")
                return try scopeID.rawValue.withCString { scopeCString in
                    try check(sqlite3_bind_text(statement, 2, scopeCString, -1, nil), operation: "bind path-free scope")
                    switch sqlite3_step(statement) {
                    case SQLITE_ROW:
                        return PathFreeCalibrationRequirement(
                            streamID: streamID,
                            scopeID: scopeID,
                            reasons: DirtyRegionReason(rawValue: UInt64(bitPattern: sqlite3_column_int64(statement, 0))),
                            createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1)) / 1_000)
                        )
                    case SQLITE_DONE:
                        return nil
                    default:
                        throw sqliteFailure(
                            operation: "step path-free requirement query",
                            code: sqlite3_errcode(try databaseHandle())
                        )
                    }
                }
            }
        }
    }

    public func restorePathFreeCalibrationRequirement(
        for streamID: EventStreamID,
        scopeID: WatchedScopeID,
        at authorizedRoot: DirtyRegionPath
    ) async throws -> Bool {
        try execute("BEGIN IMMEDIATE TRANSACTION", operation: "begin path-free restoration")
        do {
            guard let requirement = try pathFreeCalibrationRequirement(
                for: streamID,
                scopeID: scopeID
            ) else {
                try execute("COMMIT TRANSACTION", operation: "commit empty path-free restoration")
                return false
            }
            let region = try DirtyRegion(
                path: authorizedRoot,
                reasons: requirement.reasons.union([
                    .requiresCalibration,
                    .mustScanSubdirectories,
                ]),
                maximumCursor: nil
            )
            try merge(regions: [region], streamID: streamID)
            try deletePathFreeRequirement(for: streamID, scopeID: scopeID)
            try execute("COMMIT TRANSACTION", operation: "commit path-free restoration")
            return true
        } catch {
            try rollback(after: error)
        }
    }

    public func saveAuthorizedBaseline(
        _ snapshot: AuthorizedBaselineSnapshot
    ) throws {
        try execute(
            "BEGIN IMMEDIATE TRANSACTION",
            operation: "begin authorized baseline snapshot write"
        )
        do {
            try insertAuthorizedBaselineSnapshot(snapshot)
            for (ordinal, root) in snapshot.roots.enumerated() {
                try insertAuthorizedBaselineRoot(
                    root,
                    baselineID: snapshot.id,
                    ordinal: ordinal
                )
            }
            try execute(
                "COMMIT TRANSACTION",
                operation: "commit authorized baseline snapshot write"
            )
        } catch {
            try rollback(after: error)
        }
    }

    public func latestAuthorizedBaseline(
        for scopeID: WatchedScopeID
    ) throws -> AuthorizedBaselineSnapshot? {
        guard let baselineID = try latestAuthorizedBaselineID(for: scopeID) else {
            return nil
        }
        return try readAuthorizedBaselineSnapshot(id: baselineID)
    }

    /// Deletes only expired, replaceable history. Current directory truth,
    /// unresolved dirty work, and the newest baseline for every scope are
    /// deliberately outside the deletion set.
    public func applyRetention(
        _ policy: SQLiteRetentionPolicy = .default,
        referenceDate: Date = Date()
    ) throws -> SQLiteRetentionReport {
        let cutoff = Self.milliseconds(policy.cutoff(referenceDate: referenceDate))
        let hourlyCutoff = Self.milliseconds(
            referenceDate.addingTimeInterval(-7 * 86_400)
        )
        let dirtyCutoff = Self.milliseconds(
            referenceDate.addingTimeInterval(-30 * 86_400)
        )
        try execute("BEGIN IMMEDIATE TRANSACTION", operation: "begin retention")

        do {
            let hourlyHistory = try deleteExpiredHourlyHistory(cutoff: hourlyCutoff)
            let pathHistory = try deleteExpiredPathHistory(cutoff: cutoff)
            let agedDirtyPaths = try ageDirtyPaths(cutoff: dirtyCutoff)
            let deletedNodes = try deleteExpiredDeletedNodes(cutoff: cutoff)
            try failIfRequested(at: .afterExpiredDeletedNodesBeforeBaselines)
            let baselines = try deleteExpiredReplaceableBaselines(cutoff: cutoff)
            let scanRuns = try deleteExpiredUnreferencedScanRuns(cutoff: cutoff)
            try execute("COMMIT TRANSACTION", operation: "commit retention")
            return SQLiteRetentionReport(
                deletedNodeCount: deletedNodes,
                baselineCount: baselines,
                scanRunCount: scanRuns,
                hourlyHistoryCount: hourlyHistory,
                pathHistoryCount: pathHistory,
                agedDirtyPathCount: agedDirtyPaths
            )
        } catch {
            try rollback(after: error)
        }
    }

    /// Restricts this test database to its current page count so the next
    /// growing write exercises SQLite's real `SQLITE_FULL` path.
    func constrainDatabaseGrowthForTesting() throws {
        let pageCount = try readInt32Pragma("PRAGMA page_count")
        guard pageCount > 0 else {
            throw SQLiteEventJournalError.corruptStoredValue(field: "page_count")
        }
        try execute(
            "PRAGMA max_page_count = \(pageCount)",
            operation: "constrain test database growth"
        )
    }

    /// Explicitly releases SQLite resources. Calling close repeatedly is safe;
    /// repository operations after closing report `databaseClosed`.
    public func close() throws {
        try connection.withLock { database in
            guard let handle = database else {
                return
            }

            let result = sqlite3_close_v2(handle)
            guard result == SQLITE_OK else {
                throw SQLiteEventJournalError.sqliteFailure(
                    operation: "close database",
                    code: result,
                    message: Self.errorMessage(from: handle)
                )
            }

            database = nil
        }
    }

    private static func configureAndMigrate(
        _ database: OpaquePointer,
        databaseURL: URL,
        failurePoint: SQLiteEventJournalTestFailurePoint?
    ) throws -> URL? {
        let timeoutResult = sqlite3_busy_timeout(database, 5_000)
        guard timeoutResult == SQLITE_OK else {
            throw SQLiteEventJournalError.sqliteFailure(
                operation: "configure busy timeout",
                code: timeoutResult,
                message: errorMessage(from: database)
            )
        }

        // Read before any persistent pragma so an invalid/corrupt main file is
        // classified without attempting to replace or rewrite it.
        let currentVersion = try readSchemaVersion(from: database)

        let migrationBackupURL: URL?
        if currentVersion > 0, currentVersion < Self.schemaVersion {
            migrationBackupURL = try SQLiteMigrationBackup.create(
                sourceDatabase: database,
                databaseURL: databaseURL,
                sourceVersion: currentVersion
            )
        } else {
            migrationBackupURL = nil
        }

        try execute(on: database, "PRAGMA journal_mode = WAL", operation: "enable WAL mode")
        try execute(on: database, "PRAGMA foreign_keys = ON", operation: "enable foreign keys")
        try execute(
            on: database,
            "PRAGMA synchronous = NORMAL",
            operation: "configure synchronous mode"
        )

        do {
            switch currentVersion {
            case Self.schemaVersion:
                break
            case 0:
                try migrateToVersionOne(database)
                try migrateToVersionTwo(database)
                try migrateToVersionThree(database)
                try migrateToVersionFour(database)
                try migrateToVersionFive(database)
                try migrateToVersionSix(database, failurePoint: failurePoint)
                try migrateToVersionSeven(database, failurePoint: failurePoint)
                try migrateToVersionEight(database, failurePoint: failurePoint)
            case 1:
                try migrateToVersionTwo(database)
                try migrateToVersionThree(database)
                try migrateToVersionFour(database)
                try migrateToVersionFive(database)
                try migrateToVersionSix(database, failurePoint: failurePoint)
                try migrateToVersionSeven(database, failurePoint: failurePoint)
                try migrateToVersionEight(database, failurePoint: failurePoint)
            case 2:
                try migrateToVersionThree(database)
                try migrateToVersionFour(database)
                try migrateToVersionFive(database)
                try migrateToVersionSix(database, failurePoint: failurePoint)
                try migrateToVersionSeven(database, failurePoint: failurePoint)
                try migrateToVersionEight(database, failurePoint: failurePoint)
            case 3:
                try migrateToVersionFour(database)
                try migrateToVersionFive(database)
                try migrateToVersionSix(database, failurePoint: failurePoint)
                try migrateToVersionSeven(database, failurePoint: failurePoint)
                try migrateToVersionEight(database, failurePoint: failurePoint)
            case 4:
                try migrateToVersionFive(database)
                try migrateToVersionSix(database, failurePoint: failurePoint)
                try migrateToVersionSeven(database, failurePoint: failurePoint)
                try migrateToVersionEight(database, failurePoint: failurePoint)
            case 5:
                try migrateToVersionSix(database, failurePoint: failurePoint)
                try migrateToVersionSeven(database, failurePoint: failurePoint)
                try migrateToVersionEight(database, failurePoint: failurePoint)
            case 6:
                try migrateToVersionSeven(database, failurePoint: failurePoint)
                try migrateToVersionEight(database, failurePoint: failurePoint)
            case 7:
                try migrateToVersionEight(database, failurePoint: failurePoint)
            default:
                throw SQLiteEventJournalError.unsupportedSchemaVersion(currentVersion)
            }
        } catch SQLiteEventJournalError.injectedFailure {
            guard case let .beforeMigrationCommit(version)? = failurePoint else {
                throw SQLiteEventJournalError.injectedFailure
            }
            throw SQLiteEventJournalError.migrationFailed(
                fromVersion: currentVersion,
                targetVersion: version
            )
        }

        // A persisted "active" row describes the previous process's last
        // observation, not proof that the volume stayed mounted while the app
        // was absent. Close it conservatively so the first callback in this
        // process opens a new mount generation and visible continuity gap.
        try execute(
            on: database,
            """
            UPDATE scope_mount_generation
            SET is_active = 0,
                updated_at_ms = CAST(strftime('%s', 'now') AS INTEGER) * 1000
            WHERE is_active = 1
            """,
            operation: "close stale active mount generations"
        )
        try recoverInterruptedCalibrationRuns(database)
        return migrationBackupURL
    }

    private static func migrateToVersionEight(
        _ database: OpaquePointer,
        failurePoint: SQLiteEventJournalTestFailurePoint?
    ) throws {
        try execute(
            on: database,
            "BEGIN IMMEDIATE TRANSACTION",
            operation: "begin schema migration v8"
        )
        do {
            try execute(
                on: database,
                """
                ALTER TABLE dirty_region ADD COLUMN updated_at_ms INTEGER;
                UPDATE dirty_region
                SET updated_at_ms = CAST(strftime('%s', 'now') AS INTEGER) * 1000;

                CREATE TABLE directory_history_sample (
                    stream_id TEXT NOT NULL,
                    path TEXT NOT NULL
                        CHECK(length(path) > 0 AND substr(path, 1, 1) = '/'
                            AND instr(path, char(0)) = 0),
                    bucket_kind TEXT NOT NULL
                        CHECK(bucket_kind IN ('hourly', 'daily')),
                    bucket_start_ms INTEGER NOT NULL,
                    logical_bytes INTEGER,
                    logical_delta INTEGER,
                    allocated_bytes INTEGER,
                    descendant_count INTEGER NOT NULL CHECK(descendant_count >= 0),
                    coverage TEXT NOT NULL CHECK(coverage IN ('complete', 'partial')),
                    scan_run_id TEXT NOT NULL,
                    PRIMARY KEY(stream_id, path, bucket_kind, bucket_start_ms)
                ) WITHOUT ROWID;

                CREATE INDEX directory_history_window
                    ON directory_history_sample(
                        stream_id, bucket_kind, bucket_start_ms, path
                    );
                CREATE INDEX directory_history_growth
                    ON directory_history_sample(
                        stream_id, bucket_kind, path, bucket_start_ms,
                        logical_delta
                    );

                CREATE TABLE path_free_calibration_requirement (
                    stream_id TEXT NOT NULL,
                    scope_id TEXT NOT NULL,
                    reasons INTEGER NOT NULL CHECK(reasons != 0),
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY(stream_id, scope_id)
                ) WITHOUT ROWID;

                INSERT INTO schema_migration(version, applied_at_ms, checksum)
                VALUES(8, CAST(strftime('%s', 'now') AS INTEGER) * 1000,
                    'hourly-daily-delta-history-scope-path-free-dirty-v8');
                PRAGMA user_version = 8;
                """,
                operation: "apply schema migration version 8"
            )
            try failMigrationIfRequested(version: 8, failurePoint: failurePoint)
            try execute(
                on: database,
                "COMMIT TRANSACTION",
                operation: "commit schema migration v8"
            )
        } catch let migrationError {
            do {
                try execute(
                    on: database,
                    "ROLLBACK TRANSACTION",
                    operation: "roll back schema migration v8"
                )
            } catch let rollbackError {
                throw SQLiteEventJournalError.rollbackFailed(
                    original: String(describing: migrationError),
                    rollback: String(describing: rollbackError)
                )
            }
            throw migrationError
        }
    }

    private static func migrateToVersionSeven(
        _ database: OpaquePointer,
        failurePoint: SQLiteEventJournalTestFailurePoint?
    ) throws {
        try execute(
            on: database,
            "BEGIN IMMEDIATE TRANSACTION",
            operation: "begin schema migration v7"
        )
        do {
            try execute(
                on: database,
                """
                ALTER TABLE node_current ADD COLUMN deleted_at_ms INTEGER;

                UPDATE node_current
                SET deleted_at_ms = CAST(strftime('%s', 'now') AS INTEGER) * 1000
                WHERE deleted = 1;

                CREATE INDEX node_current_expired_deleted
                    ON node_current(deleted, deleted_at_ms);

                INSERT INTO schema_migration(version, applied_at_ms, checksum)
                VALUES(7, CAST(strftime('%s', 'now') AS INTEGER) * 1000,
                    'bounded-current-history-retention-v7');

                PRAGMA user_version = 7;
                """,
                operation: "apply schema migration version 7"
            )
            try failMigrationIfRequested(version: 7, failurePoint: failurePoint)
            try execute(
                on: database,
                "COMMIT TRANSACTION",
                operation: "commit schema migration v7"
            )
        } catch let migrationError {
            do {
                try execute(
                    on: database,
                    "ROLLBACK TRANSACTION",
                    operation: "roll back schema migration v7"
                )
            } catch let rollbackError {
                throw SQLiteEventJournalError.rollbackFailed(
                    original: String(describing: migrationError),
                    rollback: String(describing: rollbackError)
                )
            }
            throw migrationError
        }
    }

    private static func migrateToVersionSix(
        _ database: OpaquePointer,
        failurePoint: SQLiteEventJournalTestFailurePoint?
    ) throws {
        try execute(
            on: database,
            "BEGIN IMMEDIATE TRANSACTION",
            operation: "begin schema migration v6"
        )
        do {
            try execute(
                on: database,
                """
                CREATE TABLE authorized_baseline_snapshot (
                    id TEXT PRIMARY KEY NOT NULL
                        CHECK(length(id) > 0 AND instr(id, char(0)) = 0),
                    started_at_ms INTEGER NOT NULL,
                    committed_at_ms INTEGER NOT NULL
                        CHECK(committed_at_ms >= started_at_ms),
                    app_version TEXT NOT NULL
                        CHECK(length(app_version) > 0 AND length(app_version) <= 128
                            AND instr(app_version, char(0)) = 0),
                    schema_version INTEGER NOT NULL CHECK(schema_version > 0),
                    volume_observed_at_ms INTEGER NOT NULL,
                    volume_uuid TEXT,
                    volume_total_bytes INTEGER
                        CHECK(volume_total_bytes IS NULL OR volume_total_bytes >= 0),
                    volume_available_bytes INTEGER
                        CHECK(volume_available_bytes IS NULL
                            OR volume_available_bytes >= 0),
                    volume_important_available_bytes INTEGER
                        CHECK(volume_important_available_bytes IS NULL
                            OR volume_important_available_bytes >= 0),
                    coverage TEXT NOT NULL CHECK(coverage = 'complete'),
                    root_count INTEGER NOT NULL CHECK(root_count > 0)
                ) WITHOUT ROWID;

                CREATE TABLE authorized_baseline_root (
                    baseline_id TEXT NOT NULL REFERENCES authorized_baseline_snapshot(id)
                        ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
                    scope_id TEXT NOT NULL
                        CHECK(length(scope_id) > 0 AND instr(scope_id, char(0)) = 0),
                    stream_id TEXT NOT NULL
                        CHECK(length(stream_id) > 0 AND instr(stream_id, char(0)) = 0),
                    root_path TEXT NOT NULL
                        CHECK(length(root_path) > 0
                            AND substr(root_path, 1, 1) = '/'
                            AND instr(root_path, char(0)) = 0),
                    logical_bytes INTEGER NOT NULL CHECK(logical_bytes >= 0),
                    allocated_bytes INTEGER NOT NULL CHECK(allocated_bytes >= 0),
                    descendant_count INTEGER NOT NULL CHECK(descendant_count >= 0),
                    entries_visited INTEGER NOT NULL CHECK(entries_visited >= 0),
                    directories_observed INTEGER NOT NULL CHECK(directories_observed > 0),
                    coverage TEXT NOT NULL CHECK(coverage = 'complete'),
                    PRIMARY KEY(baseline_id, ordinal),
                    UNIQUE(baseline_id, scope_id)
                ) WITHOUT ROWID;

                CREATE INDEX authorized_baseline_root_scope
                    ON authorized_baseline_root(scope_id, baseline_id);
                CREATE INDEX authorized_baseline_committed
                    ON authorized_baseline_snapshot(committed_at_ms DESC, id DESC);

                INSERT INTO schema_migration(version, applied_at_ms, checksum)
                VALUES(6, CAST(strftime('%s', 'now') AS INTEGER) * 1000,
                    'authorized-baseline-snapshot-v6');

                PRAGMA user_version = 6;
                """,
                operation: "apply schema migration version 6"
            )
            try failMigrationIfRequested(version: 6, failurePoint: failurePoint)
            try execute(
                on: database,
                "COMMIT TRANSACTION",
                operation: "commit schema migration v6"
            )
        } catch let migrationError {
            do {
                try execute(
                    on: database,
                    "ROLLBACK TRANSACTION",
                    operation: "roll back schema migration v6"
                )
            } catch let rollbackError {
                throw SQLiteEventJournalError.rollbackFailed(
                    original: String(describing: migrationError),
                    rollback: String(describing: rollbackError)
                )
            }
            throw migrationError
        }
    }

    private static func recoverInterruptedCalibrationRuns(_ database: OpaquePointer) throws {
        try execute(
            on: database,
            "BEGIN IMMEDIATE TRANSACTION",
            operation: "begin interrupted calibration recovery"
        )
        do {
            try execute(
                on: database,
                """
                DELETE FROM scan_node_stage
                WHERE scan_run_id IN (
                    SELECT id FROM scan_run WHERE state = 'running'
                );

                UPDATE scan_run
                SET state = 'failed',
                    finished_at_ms = CAST(strftime('%s', 'now') AS INTEGER) * 1000
                WHERE state = 'running';
                """,
                operation: "recover interrupted calibration runs"
            )
            try execute(
                on: database,
                "COMMIT TRANSACTION",
                operation: "commit interrupted calibration recovery"
            )
        } catch let recoveryError {
            do {
                try execute(
                    on: database,
                    "ROLLBACK TRANSACTION",
                    operation: "roll back interrupted calibration recovery"
                )
            } catch let rollbackError {
                throw SQLiteEventJournalError.rollbackFailed(
                    original: String(describing: recoveryError),
                    rollback: String(describing: rollbackError)
                )
            }
            throw recoveryError
        }
    }

    private static func migrateToVersionFive(_ database: OpaquePointer) throws {
        try execute(
            on: database,
            "BEGIN IMMEDIATE TRANSACTION",
            operation: "begin schema migration v5"
        )
        do {
            try execute(
                on: database,
                """
                CREATE TABLE watched_scope_bookmark (
                    scope_id TEXT PRIMARY KEY NOT NULL
                        CHECK(length(scope_id) > 0 AND instr(scope_id, char(0)) = 0),
                    bookmark BLOB NOT NULL
                        CHECK(length(bookmark) > 0 AND length(bookmark) <= 1048576),
                    expected_root TEXT NOT NULL
                        CHECK(length(expected_root) > 0
                            AND substr(expected_root, 1, 1) = '/'
                            AND instr(expected_root, char(0)) = 0),
                    expected_volume_uuid TEXT NOT NULL
                        CHECK(length(expected_volume_uuid) = 36
                            AND instr(expected_volume_uuid, char(0)) = 0),
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                ) WITHOUT ROWID;

                INSERT INTO schema_migration(version, applied_at_ms, checksum)
                VALUES(5, CAST(strftime('%s', 'now') AS INTEGER) * 1000,
                    'security-scoped-watch-bookmark-v5');

                PRAGMA user_version = 5;
                """,
                operation: "apply schema migration version 5"
            )
            try execute(
                on: database,
                "COMMIT TRANSACTION",
                operation: "commit schema migration v5"
            )
        } catch let migrationError {
            do {
                try execute(
                    on: database,
                    "ROLLBACK TRANSACTION",
                    operation: "roll back schema migration v5"
                )
            } catch let rollbackError {
                throw SQLiteEventJournalError.rollbackFailed(
                    original: String(describing: migrationError),
                    rollback: String(describing: rollbackError)
                )
            }
            throw migrationError
        }
    }

    private static func migrateToVersionFour(_ database: OpaquePointer) throws {
        try execute(
            on: database,
            "BEGIN IMMEDIATE TRANSACTION",
            operation: "begin schema migration v4"
        )
        do {
            try execute(
                on: database,
                """
                CREATE TABLE scope_mount_generation (
                    scope_id TEXT PRIMARY KEY NOT NULL
                        CHECK(length(scope_id) > 0 AND instr(scope_id, char(0)) = 0),
                    mount_generation TEXT NOT NULL
                        CHECK(length(mount_generation) > 0
                            AND instr(mount_generation, char(0)) = 0),
                    mount_path TEXT NOT NULL
                        CHECK(length(mount_path) > 0
                            AND substr(mount_path, 1, 1) = '/'
                            AND instr(mount_path, char(0)) = 0),
                    volume_uuid TEXT,
                    is_active INTEGER NOT NULL CHECK(is_active IN (0, 1)),
                    updated_at_ms INTEGER NOT NULL
                ) WITHOUT ROWID;

                INSERT INTO schema_migration(version, applied_at_ms, checksum)
                VALUES(4, CAST(strftime('%s', 'now') AS INTEGER) * 1000,
                    'scope-mount-generation-v4');

                PRAGMA user_version = 4;
                """,
                operation: "apply schema migration version 4"
            )
            try execute(
                on: database,
                "COMMIT TRANSACTION",
                operation: "commit schema migration v4"
            )
        } catch let migrationError {
            do {
                try execute(
                    on: database,
                    "ROLLBACK TRANSACTION",
                    operation: "roll back schema migration v4"
                )
            } catch let rollbackError {
                throw SQLiteEventJournalError.rollbackFailed(
                    original: String(describing: migrationError),
                    rollback: String(describing: rollbackError)
                )
            }
            throw migrationError
        }
    }

    private static func migrateToVersionThree(_ database: OpaquePointer) throws {
        try execute(
            on: database,
            "BEGIN IMMEDIATE TRANSACTION",
            operation: "begin schema migration v3"
        )
        do {
            try execute(
                on: database,
                """
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
                    entries_seen INTEGER NOT NULL DEFAULT 0 CHECK(entries_seen >= 0),
                    directories_staged INTEGER NOT NULL DEFAULT 0
                        CHECK(directories_staged >= 0),
                    started_at_ms INTEGER NOT NULL,
                    finished_at_ms INTEGER
                ) WITHOUT ROWID;

                CREATE TABLE scan_node_stage (
                    scan_run_id TEXT NOT NULL REFERENCES scan_run(id) ON DELETE CASCADE,
                    path TEXT NOT NULL,
                    logical_bytes INTEGER CHECK(logical_bytes IS NULL OR logical_bytes >= 0),
                    allocated_bytes INTEGER CHECK(
                        allocated_bytes IS NULL OR allocated_bytes >= 0
                    ),
                    descendant_count INTEGER NOT NULL CHECK(descendant_count >= 0),
                    coverage TEXT NOT NULL CHECK(coverage IN ('complete', 'partial')),
                    PRIMARY KEY(scan_run_id, path)
                ) WITHOUT ROWID;

                CREATE TABLE node_current (
                    stream_id TEXT NOT NULL,
                    path TEXT NOT NULL,
                    logical_bytes INTEGER CHECK(logical_bytes IS NULL OR logical_bytes >= 0),
                    allocated_bytes INTEGER CHECK(
                        allocated_bytes IS NULL OR allocated_bytes >= 0
                    ),
                    descendant_count INTEGER NOT NULL CHECK(descendant_count >= 0),
                    coverage TEXT NOT NULL CHECK(coverage IN ('complete', 'partial')),
                    last_scan_run_id TEXT NOT NULL REFERENCES scan_run(id),
                    deleted INTEGER NOT NULL DEFAULT 0 CHECK(deleted IN (0, 1)),
                    PRIMARY KEY(stream_id, path)
                ) WITHOUT ROWID;

                CREATE INDEX node_current_scan_region
                    ON node_current(stream_id, path, deleted);

                INSERT INTO schema_migration(version, applied_at_ms, checksum)
                VALUES(3, CAST(strftime('%s', 'now') AS INTEGER) * 1000,
                    'calibration-v3-staging-finalization');

                PRAGMA user_version = 3;
                """,
                operation: "apply schema migration version 3"
            )
            try execute(
                on: database,
                "COMMIT TRANSACTION",
                operation: "commit schema migration v3"
            )
        } catch let migrationError {
            do {
                try execute(
                    on: database,
                    "ROLLBACK TRANSACTION",
                    operation: "roll back schema migration v3"
                )
            } catch let rollbackError {
                throw SQLiteEventJournalError.rollbackFailed(
                    original: String(describing: migrationError),
                    rollback: String(describing: rollbackError)
                )
            }
            throw migrationError
        }
    }

    private static func migrateToVersionTwo(_ database: OpaquePointer) throws {
        try execute(on: database, "BEGIN IMMEDIATE TRANSACTION", operation: "begin schema migration v2")
        do {
            try execute(
                on: database,
                """
                ALTER TABLE dirty_region RENAME TO dirty_region_v1;

                CREATE TABLE dirty_region (
                    stream_id TEXT NOT NULL
                        CHECK(length(stream_id) > 0 AND instr(stream_id, char(0)) = 0),
                    path TEXT NOT NULL
                        CHECK(length(path) > 0 AND substr(path, 1, 1) = '/'
                            AND instr(path, char(0)) = 0),
                    reasons INTEGER NOT NULL CHECK(reasons != 0),
                    maximum_cursor_be BLOB CHECK(
                        maximum_cursor_be IS NULL OR length(maximum_cursor_be) = 8
                    ),
                    revision_be BLOB NOT NULL CHECK(length(revision_be) = 8),
                    PRIMARY KEY(stream_id, path)
                ) WITHOUT ROWID;

                INSERT INTO dirty_region(
                    stream_id, path, reasons, maximum_cursor_be, revision_be
                )
                SELECT stream_id, path, reasons, maximum_cursor_be,
                    X'0000000000000001'
                FROM dirty_region_v1;

                DROP TABLE dirty_region_v1;

                INSERT INTO schema_migration(version, applied_at_ms, checksum)
                VALUES(2, CAST(strftime('%s', 'now') AS INTEGER) * 1000,
                    'dirty-region-v2-optional-cursor-revision');

                PRAGMA user_version = 2;
                """,
                operation: "apply schema migration version 2"
            )
            try execute(on: database, "COMMIT TRANSACTION", operation: "commit schema migration v2")
        } catch let migrationError {
            do {
                try execute(on: database, "ROLLBACK TRANSACTION", operation: "roll back schema migration v2")
            } catch let rollbackError {
                throw SQLiteEventJournalError.rollbackFailed(
                    original: String(describing: migrationError),
                    rollback: String(describing: rollbackError)
                )
            }
            throw migrationError
        }
    }

    private static func migrateToVersionOne(_ database: OpaquePointer) throws {
        try execute(
            on: database,
            "BEGIN IMMEDIATE TRANSACTION",
            operation: "begin schema migration"
        )

        do {
            try execute(
                on: database,
                """
                CREATE TABLE schema_migration (
                    version INTEGER PRIMARY KEY,
                    applied_at_ms INTEGER NOT NULL,
                    checksum TEXT NOT NULL
                );

                CREATE TABLE event_checkpoint (
                    stream_id TEXT PRIMARY KEY NOT NULL
                        CHECK(length(stream_id) > 0 AND instr(stream_id, char(0)) = 0),
                    cursor_be BLOB NOT NULL CHECK(length(cursor_be) = 8)
                ) WITHOUT ROWID;

                CREATE TABLE dirty_region (
                    stream_id TEXT NOT NULL,
                    path TEXT NOT NULL
                        CHECK(length(path) > 0 AND substr(path, 1, 1) = '/'
                            AND instr(path, char(0)) = 0),
                    reasons INTEGER NOT NULL CHECK(reasons != 0),
                    maximum_cursor_be BLOB NOT NULL CHECK(length(maximum_cursor_be) = 8),
                    PRIMARY KEY(stream_id, path),
                    FOREIGN KEY(stream_id) REFERENCES event_checkpoint(stream_id)
                        ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
                ) WITHOUT ROWID;

                INSERT INTO schema_migration(version, applied_at_ms, checksum)
                VALUES(1, CAST(strftime('%s', 'now') AS INTEGER) * 1000,
                    'event-journal-v1-big-endian-cursor');

                PRAGMA user_version = 1;
                """,
                operation: "apply schema migration version 1"
            )
            try execute(
                on: database,
                "COMMIT TRANSACTION",
                operation: "commit schema migration"
            )
        } catch let migrationError {
            do {
                try execute(
                    on: database,
                    "ROLLBACK TRANSACTION",
                    operation: "roll back schema migration"
                )
            } catch let rollbackError {
                throw SQLiteEventJournalError.rollbackFailed(
                    original: String(describing: migrationError),
                    rollback: String(describing: rollbackError)
                )
            }
            throw migrationError
        }
    }

    private static func readSchemaVersion(from database: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            database,
            "PRAGMA user_version",
            -1,
            &statement,
            nil
        )
        guard prepareResult == SQLITE_OK, let statement else {
            throw classifiedSQLiteFailure(
                operation: "prepare schema-version query",
                code: prepareResult,
                database: database
            )
        }
        defer {
            _ = sqlite3_finalize(statement)
        }

        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW else {
            throw classifiedSQLiteFailure(
                operation: "step schema-version query",
                code: stepResult,
                database: database
            )
        }

        return sqlite3_column_int(statement, 0)
    }

    private func insertAuthorizedBaselineSnapshot(
        _ snapshot: AuthorizedBaselineSnapshot
    ) throws {
        let sql = """
            INSERT INTO authorized_baseline_snapshot(
                id, started_at_ms, committed_at_ms, app_version, schema_version,
                volume_observed_at_ms, volume_uuid, volume_total_bytes,
                volume_available_bytes, volume_important_available_bytes,
                coverage, root_count
            ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 'complete', ?11)
            """
        try withStatement(sql, operation: "insert authorized baseline snapshot") { statement in
            try bind(snapshot.id.rawValue, to: statement, index: 1, operation: "bind baseline ID")
            try check(
                sqlite3_bind_int64(statement, 2, Self.milliseconds(snapshot.startedAt)),
                operation: "bind baseline start"
            )
            try check(
                sqlite3_bind_int64(statement, 3, Self.milliseconds(snapshot.committedAt)),
                operation: "bind baseline commit"
            )
            try bind(snapshot.build.appVersion, to: statement, index: 4, operation: "bind baseline app version")
            try check(
                sqlite3_bind_int64(statement, 5, Int64(snapshot.build.schemaVersion)),
                operation: "bind baseline schema version"
            )
            try check(
                sqlite3_bind_int64(
                    statement,
                    6,
                    Self.milliseconds(snapshot.startupVolume.observedAt)
                ),
                operation: "bind volume observation time"
            )
            try bind(
                snapshot.startupVolume.volumeUUID?.uuidString.lowercased(),
                to: statement,
                index: 7,
                operation: "bind baseline volume UUID"
            )
            try bind(
                snapshot.startupVolume.totalBytes?.value,
                to: statement,
                index: 8,
                operation: "bind baseline volume total"
            )
            try bind(
                snapshot.startupVolume.availableBytes?.value,
                to: statement,
                index: 9,
                operation: "bind baseline volume available"
            )
            try bind(
                snapshot.startupVolume.availableForImportantUsageBytes?.value,
                to: statement,
                index: 10,
                operation: "bind baseline volume important-usage capacity"
            )
            try check(
                sqlite3_bind_int64(statement, 11, Int64(snapshot.roots.count)),
                operation: "bind baseline root count"
            )
            try stepExpectingDone(statement, operation: "write authorized baseline snapshot")
        }
    }

    private func insertAuthorizedBaselineRoot(
        _ root: AuthorizedBaselineRootSnapshot,
        baselineID: AuthorizedBaselineID,
        ordinal: Int
    ) throws {
        let sql = """
            INSERT INTO authorized_baseline_root(
                baseline_id, ordinal, scope_id, stream_id, root_path,
                logical_bytes, allocated_bytes, descendant_count,
                entries_visited, directories_observed, coverage
            ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 'complete')
            """
        try withStatement(sql, operation: "insert authorized baseline root") { statement in
            try bind(baselineID.rawValue, to: statement, index: 1, operation: "bind root baseline ID")
            try check(sqlite3_bind_int64(statement, 2, Int64(ordinal)), operation: "bind root ordinal")
            try bind(root.context.scopeID.rawValue, to: statement, index: 3, operation: "bind root scope ID")
            try bind(root.context.streamID.rawValue, to: statement, index: 4, operation: "bind root stream ID")
            try bind(root.context.root.rawValue, to: statement, index: 5, operation: "bind root path")
            try check(sqlite3_bind_int64(statement, 6, root.logicalBytes.value), operation: "bind root logical bytes")
            try check(sqlite3_bind_int64(statement, 7, root.allocatedBytes.value), operation: "bind root allocated bytes")
            try check(sqlite3_bind_int64(statement, 8, root.descendantCount), operation: "bind root descendants")
            try check(sqlite3_bind_int64(statement, 9, root.entriesVisited), operation: "bind root entries")
            try check(sqlite3_bind_int64(statement, 10, root.directoriesObserved), operation: "bind root directories")
            try stepExpectingDone(statement, operation: "write authorized baseline root")
        }
    }

    private func latestAuthorizedBaselineID(
        for scopeID: WatchedScopeID
    ) throws -> AuthorizedBaselineID? {
        let sql = """
            SELECT snapshot.id
            FROM authorized_baseline_snapshot AS snapshot
            INNER JOIN authorized_baseline_root AS root
                ON root.baseline_id = snapshot.id
            WHERE root.scope_id = ?1
            ORDER BY snapshot.committed_at_ms DESC, snapshot.id DESC
            LIMIT 1
            """
        return try withStatement(sql, operation: "read latest authorized baseline ID") { statement in
            try bind(scopeID.rawValue, to: statement, index: 1, operation: "bind latest baseline scope")
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                do {
                    return try AuthorizedBaselineID(
                        readText(
                            from: statement,
                            column: 0,
                            field: "authorized_baseline_snapshot.id"
                        )
                    )
                } catch {
                    throw SQLiteEventJournalError.corruptStoredValue(
                        field: "authorized_baseline_snapshot.id"
                    )
                }
            case SQLITE_DONE:
                return nil
            default:
                throw sqliteFailure(operation: "step latest baseline query", code: result)
            }
        }
    }

    private func readAuthorizedBaselineSnapshot(
        id: AuthorizedBaselineID
    ) throws -> AuthorizedBaselineSnapshot {
        let sql = """
            SELECT started_at_ms, committed_at_ms, app_version, schema_version,
                volume_observed_at_ms, volume_uuid, volume_total_bytes,
                volume_available_bytes, volume_important_available_bytes, root_count
            FROM authorized_baseline_snapshot
            WHERE id = ?1
            """
        let header: StoredAuthorizedBaselineHeader = try withStatement(
            sql,
            operation: "read authorized baseline snapshot"
        ) { statement in
            try bind(id.rawValue, to: statement, index: 1, operation: "bind baseline lookup ID")
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else {
                if result == SQLITE_DONE {
                    throw SQLiteEventJournalError.corruptStoredValue(
                        field: "authorized_baseline_snapshot"
                    )
                }
                throw sqliteFailure(operation: "step baseline snapshot query", code: result)
            }
            return StoredAuthorizedBaselineHeader(
                startedAt: try readDate(from: statement, column: 0, field: "authorized_baseline_snapshot.started_at_ms"),
                committedAt: try readDate(from: statement, column: 1, field: "authorized_baseline_snapshot.committed_at_ms"),
                appVersion: try readText(from: statement, column: 2, field: "authorized_baseline_snapshot.app_version"),
                schemaVersion: try readPositiveInt(from: statement, column: 3, field: "authorized_baseline_snapshot.schema_version"),
                volumeObservedAt: try readDate(from: statement, column: 4, field: "authorized_baseline_snapshot.volume_observed_at_ms"),
                volumeUUID: try readOptionalUUID(from: statement, column: 5, field: "authorized_baseline_snapshot.volume_uuid"),
                volumeTotalBytes: try readOptionalByteCount(from: statement, column: 6, field: "authorized_baseline_snapshot.volume_total_bytes"),
                volumeAvailableBytes: try readOptionalByteCount(from: statement, column: 7, field: "authorized_baseline_snapshot.volume_available_bytes"),
                volumeImportantAvailableBytes: try readOptionalByteCount(from: statement, column: 8, field: "authorized_baseline_snapshot.volume_important_available_bytes"),
                rootCount: try readPositiveInt(from: statement, column: 9, field: "authorized_baseline_snapshot.root_count")
            )
        }
        let roots = try readAuthorizedBaselineRoots(id: id)
        guard roots.count == header.rootCount else {
            throw SQLiteEventJournalError.corruptStoredValue(
                field: "authorized_baseline_snapshot.root_count"
            )
        }

        do {
            return try AuthorizedBaselineSnapshot(
                id: id,
                startedAt: header.startedAt,
                committedAt: header.committedAt,
                build: AuthorizedBaselineBuildMetadata(
                    appVersion: header.appVersion,
                    schemaVersion: header.schemaVersion
                ),
                startupVolume: StartupVolumeCapacitySnapshot(
                    observedAt: header.volumeObservedAt,
                    volumeUUID: header.volumeUUID,
                    totalBytes: header.volumeTotalBytes,
                    availableBytes: header.volumeAvailableBytes,
                    availableForImportantUsageBytes: header.volumeImportantAvailableBytes
                ),
                roots: roots
            )
        } catch {
            throw SQLiteEventJournalError.corruptStoredValue(
                field: "authorized_baseline_snapshot"
            )
        }
    }

    private func readAuthorizedBaselineRoots(
        id: AuthorizedBaselineID
    ) throws -> [AuthorizedBaselineRootSnapshot] {
        let sql = """
            SELECT scope_id, stream_id, root_path, logical_bytes, allocated_bytes,
                descendant_count, entries_visited, directories_observed
            FROM authorized_baseline_root
            WHERE baseline_id = ?1
            ORDER BY ordinal ASC
            """
        return try withStatement(sql, operation: "read authorized baseline roots") { statement in
            try bind(id.rawValue, to: statement, index: 1, operation: "bind baseline roots ID")
            var roots: [AuthorizedBaselineRootSnapshot] = []
            while true {
                let result = sqlite3_step(statement)
                switch result {
                case SQLITE_ROW:
                    do {
                        let context = AuthorizedBaselineScanContext(
                            scopeID: try WatchedScopeID(readText(from: statement, column: 0, field: "authorized_baseline_root.scope_id")),
                            root: try DirtyRegionPath(readText(from: statement, column: 2, field: "authorized_baseline_root.root_path")),
                            streamID: try EventStreamID(readText(from: statement, column: 1, field: "authorized_baseline_root.stream_id"))
                        )
                        roots.append(
                            try AuthorizedBaselineRootSnapshot(
                                context: context,
                                logicalBytes: readRequiredByteCount(from: statement, column: 3, field: "authorized_baseline_root.logical_bytes"),
                                allocatedBytes: readRequiredByteCount(from: statement, column: 4, field: "authorized_baseline_root.allocated_bytes"),
                                descendantCount: readNonnegativeInt64(from: statement, column: 5, field: "authorized_baseline_root.descendant_count"),
                                entriesVisited: readNonnegativeInt64(from: statement, column: 6, field: "authorized_baseline_root.entries_visited"),
                                directoriesObserved: Int64(readPositiveInt(from: statement, column: 7, field: "authorized_baseline_root.directories_observed"))
                            )
                        )
                    } catch let error as SQLiteEventJournalError {
                        throw error
                    } catch {
                        throw SQLiteEventJournalError.corruptStoredValue(
                            field: "authorized_baseline_root"
                        )
                    }
                case SQLITE_DONE:
                    return roots
                default:
                    throw sqliteFailure(operation: "step baseline roots query", code: result)
                }
            }
        }
    }

    private func readScopeMountGeneration(
        for scopeID: WatchedScopeID
    ) throws -> ScopeMountGeneration? {
        let sql = """
            SELECT mount_generation, mount_path, volume_uuid, is_active
            FROM scope_mount_generation
            WHERE scope_id = ?1
            """
        return try withStatement(sql, operation: "read scope mount generation") { statement in
            try scopeID.rawValue.withCString { scopeCString in
                try check(
                    sqlite3_bind_text(statement, 1, scopeCString, -1, nil),
                    operation: "bind scope ID for mount read"
                )
                let result = sqlite3_step(statement)
                switch result {
                case SQLITE_ROW:
                    let generationRawValue = try readText(
                        from: statement,
                        column: 0,
                        field: "scope_mount_generation.mount_generation"
                    )
                    let mountPathRawValue = try readText(
                        from: statement,
                        column: 1,
                        field: "scope_mount_generation.mount_path"
                    )
                    let volumeUUIDRawValue = try readOptionalText(
                        from: statement,
                        column: 2,
                        field: "scope_mount_generation.volume_uuid"
                    )
                    guard sqlite3_column_type(statement, 3) == SQLITE_INTEGER else {
                        throw SQLiteEventJournalError.corruptStoredValue(
                            field: "scope_mount_generation.is_active"
                        )
                    }
                    let isActiveRawValue = sqlite3_column_int(statement, 3)
                    guard isActiveRawValue == 0 || isActiveRawValue == 1 else {
                        throw SQLiteEventJournalError.corruptStoredValue(
                            field: "scope_mount_generation.is_active"
                        )
                    }
                    do {
                        let volumeUUID: UUID?
                        if let volumeUUIDRawValue {
                            guard let parsedUUID = UUID(uuidString: volumeUUIDRawValue) else {
                                throw SQLiteEventJournalError.corruptStoredValue(
                                    field: "scope_mount_generation.volume_uuid"
                                )
                            }
                            volumeUUID = parsedUUID
                        } else {
                            volumeUUID = nil
                        }
                        return ScopeMountGeneration(
                            scopeID: scopeID,
                            generationID: try MountGenerationID(generationRawValue),
                            mountPath: try DirtyRegionPath(mountPathRawValue),
                            volumeUUID: volumeUUID,
                            isActive: isActiveRawValue == 1
                        )
                    } catch let error as SQLiteEventJournalError {
                        throw error
                    } catch {
                        throw SQLiteEventJournalError.corruptStoredValue(
                            field: "scope_mount_generation"
                        )
                    }
                case SQLITE_DONE:
                    return nil
                default:
                    throw sqliteFailure(operation: "step scope mount query", code: result)
                }
            }
        }
    }

    private func upsertScopeMountGeneration(_ generation: ScopeMountGeneration) throws {
        let sql = """
            INSERT INTO scope_mount_generation(
                scope_id, mount_generation, mount_path, volume_uuid,
                is_active, updated_at_ms
            ) VALUES(
                ?1, ?2, ?3, ?4, ?5,
                CAST(strftime('%s', 'now') AS INTEGER) * 1000
            )
            ON CONFLICT(scope_id) DO UPDATE SET
                mount_generation = excluded.mount_generation,
                mount_path = excluded.mount_path,
                volume_uuid = excluded.volume_uuid,
                is_active = excluded.is_active,
                updated_at_ms = excluded.updated_at_ms
            """
        let volumeUUID = generation.volumeUUID?.uuidString.lowercased()
        try withStatement(sql, operation: "upsert scope mount generation") { statement in
            try generation.scopeID.rawValue.withCString { scopeCString in
                try generation.generationID.rawValue.withCString { generationCString in
                    try generation.mountPath.rawValue.withCString { mountPathCString in
                        try check(
                            sqlite3_bind_text(statement, 1, scopeCString, -1, nil),
                            operation: "bind scope ID for mount write"
                        )
                        try check(
                            sqlite3_bind_text(statement, 2, generationCString, -1, nil),
                            operation: "bind mount generation for write"
                        )
                        try check(
                            sqlite3_bind_text(statement, 3, mountPathCString, -1, nil),
                            operation: "bind mount path for write"
                        )
                        try bind(
                            volumeUUID,
                            to: statement,
                            index: 4,
                            operation: "bind volume UUID for mount write"
                        )
                        try check(
                            sqlite3_bind_int(statement, 5, generation.isActive ? 1 : 0),
                            operation: "bind mount active state"
                        )
                        try stepExpectingDone(statement, operation: "write scope mount generation")
                    }
                }
            }
        }
    }

    private func readCheckpoint(for streamID: EventStreamID) throws -> EventJournalCursor? {
        let sql = "SELECT cursor_be FROM event_checkpoint WHERE stream_id = ?1"

        return try withStatement(sql, operation: "read event checkpoint") { statement in
            try streamID.rawValue.withCString { streamCString in
                try check(
                    sqlite3_bind_text(statement, 1, streamCString, -1, nil),
                    operation: "bind checkpoint stream ID"
                )

                let result = sqlite3_step(statement)
                switch result {
                case SQLITE_ROW:
                    return try readCursor(
                        from: statement,
                        column: 0,
                        field: "event_checkpoint.cursor_be"
                    )
                case SQLITE_DONE:
                    return nil
                default:
                    throw sqliteFailure(operation: "step checkpoint query", code: result)
                }
            }
        }
    }

    private func deleteCheckpoint(for streamID: EventStreamID) throws {
        let sql = "DELETE FROM event_checkpoint WHERE stream_id = ?1"
        try withStatement(sql, operation: "delete invalid event checkpoint") { statement in
            try streamID.rawValue.withCString { streamCString in
                try check(
                    sqlite3_bind_text(statement, 1, streamCString, -1, nil),
                    operation: "bind invalid checkpoint stream ID"
                )
                try stepExpectingDone(statement, operation: "delete invalid checkpoint")
            }
        }
    }

    private func clearDirtyRegionCursors(for streamID: EventStreamID) throws {
        let existing = try pendingDirtyWork(for: streamID, limit: Int.max)
        for item in existing {
            guard item.revision.rawValue < UInt64.max else {
                throw SQLiteEventJournalError.revisionOverflow(
                    path: item.region.path.rawValue
                )
            }
            try delete(path: item.region.path, streamID: streamID)
            try insert(
                region: DirtyRegion(
                    path: item.region.path,
                    reasons: item.region.reasons,
                    maximumCursor: nil
                ),
                revision: DirtyRegionRevision(item.revision.rawValue + 1),
                streamID: streamID
            )
        }
    }

    private func merge(regions: [DirtyRegion], streamID: EventStreamID) throws {
        var current = try pendingDirtyWork(for: streamID, limit: Int.max)
        for incoming in regions {
            let overlapping = current.filter {
                Self.contains($0.region.path.rawValue, in: incoming.path.rawValue)
                    || Self.contains(incoming.path.rawValue, in: $0.region.path.rawValue)
            }
            let canonicalPath = ([incoming.path] + overlapping.map(\.region.path)).min {
                let lhsDepth = $0.rawValue.split(separator: "/").count
                let rhsDepth = $1.rawValue.split(separator: "/").count
                return lhsDepth == rhsDepth
                    ? $0.rawValue < $1.rawValue
                    : lhsDepth < rhsDepth
            } ?? incoming.path

            let reasons = overlapping.reduce(incoming.reasons) {
                $0.union($1.region.reasons)
            }
            let maximumCursor = ([incoming.maximumCursor] + overlapping.map(\.region.maximumCursor))
                .compactMap { $0 }
                .max()
            let maximumRevision = overlapping.map(\.revision.rawValue).max() ?? 0
            guard maximumRevision < UInt64.max else {
                throw SQLiteEventJournalError.revisionOverflow(path: canonicalPath.rawValue)
            }
            let revision = try DirtyRegionRevision(maximumRevision + 1)
            for item in overlapping {
                try delete(path: item.region.path, streamID: streamID)
            }
            let mergedRegion = try DirtyRegion(
                path: canonicalPath,
                reasons: reasons,
                maximumCursor: maximumCursor
            )
            try insert(region: mergedRegion, revision: revision, streamID: streamID)
            current.removeAll { overlapping.contains($0) }
            current.append(DirtyRegionWorkItem(region: mergedRegion, revision: revision))
        }
    }

    private func insert(
        region: DirtyRegion,
        revision: DirtyRegionRevision,
        streamID: EventStreamID
    ) throws {
        let sql = """
            INSERT INTO dirty_region(
                stream_id, path, reasons, maximum_cursor_be, revision_be,
                updated_at_ms
            )
            VALUES(?1, ?2, ?3, ?4, ?5, ?6)
            """
        let cursorBytes = region.maximumCursor.map(Self.encode)
        let revisionBytes = Self.encode(revision.rawValue)

        try withStatement(sql, operation: "insert dirty region") { statement in
            try streamID.rawValue.withCString { streamCString in
                try region.path.rawValue.withCString { pathCString in
                    try revisionBytes.withUnsafeBytes { revisionBuffer in
                        try check(
                            sqlite3_bind_text(statement, 1, streamCString, -1, nil),
                            operation: "bind dirty-region stream ID"
                        )
                        try check(
                            sqlite3_bind_text(statement, 2, pathCString, -1, nil),
                            operation: "bind dirty-region path"
                        )
                        try check(
                            sqlite3_bind_int64(
                                statement,
                                3,
                                Int64(bitPattern: region.reasons.rawValue)
                            ),
                            operation: "bind dirty-region reasons"
                        )
                        if let cursorBytes {
                            try cursorBytes.withUnsafeBytes { cursorBuffer in
                                try check(
                                    sqlite3_bind_blob(
                                        statement,
                                        4,
                                        cursorBuffer.baseAddress,
                                        Int32(cursorBuffer.count),
                                        nil
                                    ),
                                    operation: "bind dirty-region cursor"
                                )
                            }
                        } else {
                            try check(
                                sqlite3_bind_null(statement, 4),
                                operation: "bind null dirty-region cursor"
                            )
                        }
                        try check(
                            sqlite3_bind_blob(
                                statement,
                                5,
                                revisionBuffer.baseAddress,
                                Int32(revisionBuffer.count),
                                nil
                            ),
                            operation: "bind dirty-region revision"
                        )
                        try check(
                            sqlite3_bind_int64(statement, 6, Self.milliseconds(now())),
                            operation: "bind dirty-region update time"
                        )
                        try stepExpectingDone(statement, operation: "write dirty region")
                    }
                }
            }
        }
    }

    private func delete(path: DirtyRegionPath, streamID: EventStreamID) throws {
        let sql = "DELETE FROM dirty_region WHERE stream_id = ?1 AND path = ?2"
        try withStatement(sql, operation: "delete overlapping dirty region") { statement in
            try streamID.rawValue.withCString { streamCString in
                try path.rawValue.withCString { pathCString in
                    try check(sqlite3_bind_text(statement, 1, streamCString, -1, nil), operation: "bind delete stream ID")
                    try check(sqlite3_bind_text(statement, 2, pathCString, -1, nil), operation: "bind delete path")
                    try stepExpectingDone(statement, operation: "delete overlapping dirty region")
                }
            }
        }
    }

    private static func contains(_ candidate: String, in root: String) -> Bool {
        root == "/" || candidate == root || candidate.hasPrefix(root + "/")
    }

    private func readScanRun(_ runID: CalibrationRunID) throws -> ScanRunContext {
        let sql = """
            SELECT stream_id, region_path, dirty_revision_be, state
            FROM scan_run WHERE id = ?1
            """
        return try withStatement(sql, operation: "read calibration run") { statement in
            try runID.rawValue.withCString { runCString in
                try check(sqlite3_bind_text(statement, 1, runCString, -1, nil), operation: "bind scan run lookup")
                let result = sqlite3_step(statement)
                guard result == SQLITE_ROW else {
                    if result == SQLITE_DONE {
                        throw SQLiteEventJournalError.scanRunNotFound(runID.rawValue)
                    }
                    throw sqliteFailure(operation: "step scan run query", code: result)
                }
                do {
                    return ScanRunContext(
                        streamID: try EventStreamID(
                            readText(from: statement, column: 0, field: "scan_run.stream_id")
                        ),
                        regionPath: try DirtyRegionPath(
                            readText(from: statement, column: 1, field: "scan_run.region_path")
                        ),
                        revision: try DirtyRegionRevision(
                            readUInt64(from: statement, column: 2, field: "scan_run.dirty_revision_be")
                        ),
                        state: try readText(from: statement, column: 3, field: "scan_run.state")
                    )
                } catch let error as SQLiteEventJournalError {
                    throw error
                } catch {
                    throw SQLiteEventJournalError.corruptStoredValue(field: "scan_run")
                }
            }
        }
    }

    private func upsertStagedAggregate(
        _ aggregate: DirectoryMetadataAggregate,
        runID: CalibrationRunID
    ) throws {
        let sql = """
            INSERT INTO scan_node_stage(
                scan_run_id, path, logical_bytes, allocated_bytes,
                descendant_count, coverage
            ) VALUES(?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(scan_run_id, path) DO UPDATE SET
                logical_bytes = excluded.logical_bytes,
                allocated_bytes = excluded.allocated_bytes,
                descendant_count = excluded.descendant_count,
                coverage = excluded.coverage
            """
        try withStatement(sql, operation: "stage directory aggregate") { statement in
            try runID.rawValue.withCString { runCString in
                try aggregate.path.rawValue.withCString { pathCString in
                    try aggregate.coverage.storageValue.withCString { coverageCString in
                        try check(sqlite3_bind_text(statement, 1, runCString, -1, nil), operation: "bind stage run ID")
                        try check(sqlite3_bind_text(statement, 2, pathCString, -1, nil), operation: "bind stage path")
                        try bind(aggregate.logicalBytes?.value, to: statement, index: 3, operation: "bind stage logical bytes")
                        try bind(aggregate.allocatedBytes?.value, to: statement, index: 4, operation: "bind stage allocated bytes")
                        try check(sqlite3_bind_int64(statement, 5, aggregate.descendantCount), operation: "bind stage descendant count")
                        try check(sqlite3_bind_text(statement, 6, coverageCString, -1, nil), operation: "bind stage coverage")
                        try stepExpectingDone(statement, operation: "write staged aggregate")
                    }
                }
            }
        }
    }

    private func stagedSummary(
        runID: CalibrationRunID,
        root: DirtyRegionPath
    ) throws -> (count: Int64, containsRoot: Bool, partialCount: Int64) {
        let sql = """
            SELECT COUNT(*),
                COALESCE(SUM(CASE WHEN path = ?2 THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN coverage = 'partial' THEN 1 ELSE 0 END), 0)
            FROM scan_node_stage WHERE scan_run_id = ?1
            """
        return try withStatement(sql, operation: "summarize staged calibration") { statement in
            try runID.rawValue.withCString { runCString in
                try root.rawValue.withCString { rootCString in
                    try check(sqlite3_bind_text(statement, 1, runCString, -1, nil), operation: "bind stage summary run ID")
                    try check(sqlite3_bind_text(statement, 2, rootCString, -1, nil), operation: "bind stage summary root")
                    let result = sqlite3_step(statement)
                    guard result == SQLITE_ROW else {
                        throw sqliteFailure(operation: "step stage summary", code: result)
                    }
                    return (
                        sqlite3_column_int64(statement, 0),
                        sqlite3_column_int64(statement, 1) == 1,
                        sqlite3_column_int64(statement, 2)
                    )
                }
            }
        }
    }

    private func dirtyRevision(
        streamID: EventStreamID,
        path: DirtyRegionPath
    ) throws -> DirtyRegionRevision? {
        let sql = """
            SELECT revision_be FROM dirty_region
            WHERE stream_id = ?1 AND path = ?2
            """
        return try withStatement(sql, operation: "read dirty revision") { statement in
            try streamID.rawValue.withCString { streamCString in
                try path.rawValue.withCString { pathCString in
                    try check(sqlite3_bind_text(statement, 1, streamCString, -1, nil), operation: "bind dirty revision stream")
                    try check(sqlite3_bind_text(statement, 2, pathCString, -1, nil), operation: "bind dirty revision path")
                    let result = sqlite3_step(statement)
                    switch result {
                    case SQLITE_ROW:
                        return try DirtyRegionRevision(
                            readUInt64(from: statement, column: 0, field: "dirty_region.revision_be")
                        )
                    case SQLITE_DONE:
                        return nil
                    default:
                        throw sqliteFailure(operation: "step dirty revision query", code: result)
                    }
                }
            }
        }
    }

    private func markMissingDirectoriesDeleted(
        streamID: EventStreamID,
        region: DirtyRegionPath,
        runID: CalibrationRunID
    ) throws {
        let sql = """
            UPDATE node_current
            SET deleted = 1,
                deleted_at_ms = CAST(strftime('%s', 'now') AS INTEGER) * 1000,
                last_scan_run_id = ?1
            WHERE stream_id = ?2
                AND (?3 = '/' OR path = ?3 OR substr(path, 1, length(?3) + 1) = ?3 || '/')
                AND NOT EXISTS (
                    SELECT 1 FROM scan_node_stage staged
                    WHERE staged.scan_run_id = ?1 AND staged.path = node_current.path
                )
            """
        try withStatement(sql, operation: "mark missing directories deleted") { statement in
            try runID.rawValue.withCString { runCString in
                try streamID.rawValue.withCString { streamCString in
                    try region.rawValue.withCString { regionCString in
                        try check(sqlite3_bind_text(statement, 1, runCString, -1, nil), operation: "bind deletion scan run")
                        try check(sqlite3_bind_text(statement, 2, streamCString, -1, nil), operation: "bind deletion stream")
                        try check(sqlite3_bind_text(statement, 3, regionCString, -1, nil), operation: "bind deletion region")
                        try stepExpectingDone(statement, operation: "mark missing directories deleted")
                    }
                }
            }
        }
    }

    private func publishStagedDirectories(
        streamID: EventStreamID,
        runID: CalibrationRunID
    ) throws {
        let sql = """
            INSERT INTO node_current(
                stream_id, path, logical_bytes, allocated_bytes,
                descendant_count, coverage, last_scan_run_id, deleted,
                deleted_at_ms
            )
            SELECT ?1, path, logical_bytes, allocated_bytes,
                descendant_count, coverage, scan_run_id, 0, NULL
            FROM scan_node_stage
            WHERE scan_run_id = ?2
            ON CONFLICT(stream_id, path) DO UPDATE SET
                logical_bytes = excluded.logical_bytes,
                allocated_bytes = excluded.allocated_bytes,
                descendant_count = excluded.descendant_count,
                coverage = excluded.coverage,
                last_scan_run_id = excluded.last_scan_run_id,
                deleted = 0,
                deleted_at_ms = NULL
            """
        try withStatement(sql, operation: "publish staged directories") { statement in
            try streamID.rawValue.withCString { streamCString in
                try runID.rawValue.withCString { runCString in
                    try check(sqlite3_bind_text(statement, 1, streamCString, -1, nil), operation: "bind publish stream")
                    try check(sqlite3_bind_text(statement, 2, runCString, -1, nil), operation: "bind publish run")
                    try stepExpectingDone(statement, operation: "publish staged directories")
                }
            }
        }
    }

    private func finishScanRun(
        _ runID: CalibrationRunID,
        state: String,
        report: CalibrationReport?
    ) throws {
        let sql = """
            UPDATE scan_run SET
                state = ?2,
                coverage = ?3,
                entries_seen = ?4,
                directories_staged = ?5,
                finished_at_ms = ?6
            WHERE id = ?1
            """
        let finishedAt = Int64(Date().timeIntervalSince1970 * 1_000)
        try withStatement(sql, operation: "finish calibration run") { statement in
            try runID.rawValue.withCString { runCString in
                try state.withCString { stateCString in
                    try check(sqlite3_bind_text(statement, 1, runCString, -1, nil), operation: "bind finished run ID")
                    try check(sqlite3_bind_text(statement, 2, stateCString, -1, nil), operation: "bind finished run state")
                    if let report {
                        try report.coverage.storageValue.withCString { coverageCString in
                            try check(sqlite3_bind_text(statement, 3, coverageCString, -1, nil), operation: "bind finished coverage")
                            try check(sqlite3_bind_int64(statement, 4, report.entriesVisited), operation: "bind finished entries")
                            try check(sqlite3_bind_int64(statement, 5, report.directoriesStaged), operation: "bind finished directories")
                            try check(sqlite3_bind_int64(statement, 6, finishedAt), operation: "bind finished time")
                            try stepExpectingDone(statement, operation: "update calibration run")
                        }
                    } else {
                        try check(sqlite3_bind_null(statement, 3), operation: "bind null finished coverage")
                        try check(sqlite3_bind_int64(statement, 4, 0), operation: "bind zero finished entries")
                        try check(sqlite3_bind_int64(statement, 5, 0), operation: "bind zero finished directories")
                        try check(sqlite3_bind_int64(statement, 6, finishedAt), operation: "bind finished time")
                        try stepExpectingDone(statement, operation: "update calibration run")
                    }
                }
            }
        }
    }

    private func deleteStagedRows(_ runID: CalibrationRunID) throws {
        let sql = "DELETE FROM scan_node_stage WHERE scan_run_id = ?1"
        try withStatement(sql, operation: "delete staged calibration rows") { statement in
            try runID.rawValue.withCString { runCString in
                try check(sqlite3_bind_text(statement, 1, runCString, -1, nil), operation: "bind staged deletion run")
                try stepExpectingDone(statement, operation: "delete staged calibration rows")
            }
        }
    }

    private func recordDirectoryHistory(
        streamID: EventStreamID,
        runID: CalibrationRunID,
        observedAt: Date
    ) throws {
        for bucket in [DirectoryHistoryBucket.hourly, .daily] {
            let observedMilliseconds = Self.milliseconds(observedAt)
            let bucketStart = observedMilliseconds
                - observedMilliseconds % bucket.durationMilliseconds
            let sql = """
                INSERT INTO directory_history_sample(
                    stream_id, path, bucket_kind, bucket_start_ms,
                    logical_bytes, logical_delta, allocated_bytes, descendant_count,
                    coverage, scan_run_id
                )
                SELECT ?1, staged.path, ?2, ?3, staged.logical_bytes,
                    CASE
                        WHEN staged.logical_bytes IS NULL THEN NULL
                        ELSE staged.logical_bytes - COALESCE((
                            SELECT prior.logical_bytes
                            FROM directory_history_sample AS prior
                            WHERE prior.stream_id = ?1
                                AND prior.path = staged.path
                                AND prior.bucket_kind = ?2
                                AND prior.bucket_start_ms < ?3
                                AND prior.logical_bytes IS NOT NULL
                            ORDER BY prior.bucket_start_ms DESC
                            LIMIT 1
                        ), staged.logical_bytes)
                    END,
                    staged.allocated_bytes, staged.descendant_count,
                    staged.coverage, ?4
                FROM scan_node_stage AS staged
                WHERE staged.scan_run_id = ?4
                ON CONFLICT(stream_id, path, bucket_kind, bucket_start_ms)
                DO UPDATE SET
                    logical_bytes = excluded.logical_bytes,
                    logical_delta = excluded.logical_delta,
                    allocated_bytes = excluded.allocated_bytes,
                    descendant_count = excluded.descendant_count,
                    coverage = excluded.coverage,
                    scan_run_id = excluded.scan_run_id
                """
            try withStatement(sql, operation: "record directory history") { statement in
                try streamID.rawValue.withCString { streamCString in
                    try bucket.rawValue.withCString { bucketCString in
                        try runID.rawValue.withCString { runCString in
                            try check(sqlite3_bind_text(statement, 1, streamCString, -1, nil), operation: "bind history stream")
                            try check(sqlite3_bind_text(statement, 2, bucketCString, -1, nil), operation: "bind history bucket")
                            try check(sqlite3_bind_int64(statement, 3, bucketStart), operation: "bind history time")
                            try check(sqlite3_bind_text(statement, 4, runCString, -1, nil), operation: "bind history run")
                            try stepExpectingDone(statement, operation: "write directory history")
                        }
                    }
                }
            }
        }
    }

    private func deleteExpiredHourlyHistory(cutoff: Int64) throws -> Int {
        try deleteRows(
            """
            DELETE FROM directory_history_sample
            WHERE bucket_kind = 'hourly' AND bucket_start_ms < ?1
            """,
            cutoff: cutoff,
            operation: "delete expired hourly history"
        )
    }

    private func deleteExpiredPathHistory(cutoff: Int64) throws -> Int {
        try deleteRows(
            """
            DELETE FROM directory_history_sample
            WHERE bucket_start_ms < ?1
            """,
            cutoff: cutoff,
            operation: "delete expired path history"
        )
    }

    private func ageDirtyPaths(cutoff: Int64) throws -> Int {
        let markerSQL = """
            INSERT INTO path_free_calibration_requirement(
                stream_id, scope_id, reasons, created_at_ms, updated_at_ms
            )
            SELECT DISTINCT dirty.stream_id,
                COALESCE((
                    SELECT bookmark.scope_id
                    FROM watched_scope_bookmark AS bookmark
                    WHERE bookmark.expected_root = '/'
                        OR dirty.path = bookmark.expected_root
                        OR substr(
                            dirty.path,
                            1,
                            length(bookmark.expected_root) + 1
                        ) = bookmark.expected_root || '/'
                    ORDER BY length(bookmark.expected_root) DESC,
                        bookmark.scope_id ASC
                    LIMIT 1
                ), ''),
                ?1, ?2, ?2
            FROM dirty_region AS dirty
            WHERE dirty.updated_at_ms < ?3
            ON CONFLICT(stream_id, scope_id) DO UPDATE SET
                reasons = path_free_calibration_requirement.reasons | excluded.reasons,
                updated_at_ms = excluded.updated_at_ms
            """
        try withStatement(markerSQL, operation: "preserve aged dirty requirement") { statement in
            try check(
                sqlite3_bind_int64(
                    statement,
                    1,
                    Int64(bitPattern: DirtyRegionReason.requiresCalibration.rawValue)
                ),
                operation: "bind calibration reason"
            )
            try check(sqlite3_bind_int64(statement, 2, Self.milliseconds(now())), operation: "bind marker time")
            try check(sqlite3_bind_int64(statement, 3, cutoff), operation: "bind dirty cutoff")
            try stepExpectingDone(statement, operation: "write path-free requirement")
        }
        return try deleteRows(
            "DELETE FROM dirty_region WHERE updated_at_ms < ?1",
            cutoff: cutoff,
            operation: "delete aged dirty paths"
        )
    }

    private func deletePathFreeRequirement(
        for streamID: EventStreamID,
        scopeID: WatchedScopeID
    ) throws {
        try withStatement(
            """
            DELETE FROM path_free_calibration_requirement
            WHERE stream_id = ?1 AND scope_id = ?2
            """,
            operation: "delete path-free requirement"
        ) { statement in
            try streamID.rawValue.withCString { streamCString in
                try check(sqlite3_bind_text(statement, 1, streamCString, -1, nil), operation: "bind consumed path-free stream")
                try scopeID.rawValue.withCString { scopeCString in
                    try check(sqlite3_bind_text(statement, 2, scopeCString, -1, nil), operation: "bind consumed path-free scope")
                    try stepExpectingDone(statement, operation: "consume path-free requirement")
                }
            }
        }
    }

    private func deleteExpiredDeletedNodes(cutoff: Int64) throws -> Int {
        let sql = """
            DELETE FROM node_current
            WHERE deleted = 1
                AND deleted_at_ms IS NOT NULL
                AND deleted_at_ms < ?1
            """
        return try deleteRows(sql, cutoff: cutoff, operation: "delete expired nodes")
    }

    private func deleteExpiredReplaceableBaselines(cutoff: Int64) throws -> Int {
        // A snapshot is replaceable only when every scope it represents has a
        // newer snapshot. This preserves the newest complete baseline for each
        // authorized scope even when it is older than the retention window.
        let sql = """
            DELETE FROM authorized_baseline_snapshot AS expired
            WHERE expired.committed_at_ms < ?1
                AND NOT EXISTS (
                    SELECT 1
                    FROM authorized_baseline_root AS expired_root
                    WHERE expired_root.baseline_id = expired.id
                        AND NOT EXISTS (
                            SELECT 1
                            FROM authorized_baseline_root AS newer_root
                            JOIN authorized_baseline_snapshot AS newer
                                ON newer.id = newer_root.baseline_id
                            WHERE newer_root.scope_id = expired_root.scope_id
                                AND (
                                    newer.committed_at_ms > expired.committed_at_ms
                                    OR (
                                        newer.committed_at_ms = expired.committed_at_ms
                                        AND newer.id > expired.id
                                    )
                                )
                        )
                )
            """
        return try deleteRows(
            sql,
            cutoff: cutoff,
            operation: "delete expired replaceable baselines"
        )
    }

    private func deleteExpiredUnreferencedScanRuns(cutoff: Int64) throws -> Int {
        let sql = """
            DELETE FROM scan_run
            WHERE state != 'running'
                AND finished_at_ms IS NOT NULL
                AND finished_at_ms < ?1
                AND NOT EXISTS (
                    SELECT 1 FROM node_current
                    WHERE node_current.last_scan_run_id = scan_run.id
                )
            """
        return try deleteRows(
            sql,
            cutoff: cutoff,
            operation: "delete expired unreferenced scan runs"
        )
    }

    private func deleteRows(
        _ sql: String,
        cutoff: Int64,
        operation: String
    ) throws -> Int {
        try withStatement(sql, operation: operation) { statement in
            try check(
                sqlite3_bind_int64(statement, 1, cutoff),
                operation: "bind retention cutoff"
            )
            try stepExpectingDone(statement, operation: operation)
            return Int(sqlite3_changes(try databaseHandle()))
        }
    }

    private func bind(
        _ value: Int64?,
        to statement: OpaquePointer,
        index: Int32,
        operation: String
    ) throws {
        if let value {
            try check(sqlite3_bind_int64(statement, index, value), operation: operation)
        } else {
            try check(sqlite3_bind_null(statement, index), operation: operation)
        }
    }

    private func bind(
        _ value: String?,
        to statement: OpaquePointer,
        index: Int32,
        operation: String
    ) throws {
        if let value {
            try value.withCString { valueCString in
                try check(
                    sqlite3_bind_text(
                        statement,
                        index,
                        valueCString,
                        -1,
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    ),
                    operation: operation
                )
            }
        } else {
            try check(sqlite3_bind_null(statement, index), operation: operation)
        }
    }

    private func upsert(checkpoint: EventJournalCursor, streamID: EventStreamID) throws {
        let sql = """
            INSERT INTO event_checkpoint(stream_id, cursor_be)
            VALUES(?1, ?2)
            ON CONFLICT(stream_id) DO UPDATE SET cursor_be = excluded.cursor_be
            WHERE event_checkpoint.cursor_be <= excluded.cursor_be
            """
        let cursorBytes = Self.encode(checkpoint)

        try withStatement(sql, operation: "upsert event checkpoint") { statement in
            try streamID.rawValue.withCString { streamCString in
                try cursorBytes.withUnsafeBytes { cursorBuffer in
                    try check(
                        sqlite3_bind_text(statement, 1, streamCString, -1, nil),
                        operation: "bind checkpoint stream ID"
                    )
                    try check(
                        sqlite3_bind_blob(
                            statement,
                            2,
                            cursorBuffer.baseAddress,
                            Int32(cursorBuffer.count),
                            nil
                        ),
                        operation: "bind checkpoint cursor"
                    )
                    try stepExpectingDone(statement, operation: "write event checkpoint")
                }
            }
        }
    }

    private func failIfRequested(at point: SQLiteEventJournalTestFailurePoint) throws {
        guard injectedFailurePoint == point else {
            return
        }

        injectedFailurePoint = nil
        throw SQLiteEventJournalError.injectedFailure
    }

    private static func failMigrationIfRequested(
        version: Int32,
        failurePoint: SQLiteEventJournalTestFailurePoint?
    ) throws {
        guard failurePoint == .beforeMigrationCommit(version: version) else {
            return
        }
        throw SQLiteEventJournalError.injectedFailure
    }

    private func rollback(after originalError: any Error) throws -> Never {
        do {
            try execute("ROLLBACK TRANSACTION", operation: "roll back transaction")
        } catch {
            throw SQLiteEventJournalError.rollbackFailed(
                original: String(describing: originalError),
                rollback: String(describing: error)
            )
        }

        throw originalError
    }

    private func databaseHandle() throws -> OpaquePointer {
        try connection.withLock { database in
            guard let database else {
                throw SQLiteEventJournalError.databaseClosed
            }
            return database
        }
    }

    private func execute(_ sql: String, operation: String) throws {
        let database = try databaseHandle()
        try Self.execute(on: database, sql, operation: operation)
    }

    private static func execute(
        on database: OpaquePointer,
        _ sql: String,
        operation: String
    ) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorPointer)

        guard result == SQLITE_OK else {
            let message: String
            if let errorPointer {
                message = String(cString: errorPointer)
                sqlite3_free(errorPointer)
            } else {
                message = Self.errorMessage(from: database)
            }

            throw classifiedSQLiteFailure(
                operation: operation,
                code: result,
                message: message
            )
        }
    }

    private func withStatement<Result>(
        _ sql: String,
        operation: String,
        body: (OpaquePointer) throws -> Result
    ) throws -> Result {
        let database = try databaseHandle()
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)

        guard result == SQLITE_OK, let statement else {
            throw sqliteFailure(operation: operation, code: result)
        }
        defer {
            _ = sqlite3_finalize(statement)
        }

        return try body(statement)
    }

    private func check(_ result: Int32, operation: String) throws {
        guard result == SQLITE_OK else {
            throw sqliteFailure(operation: operation, code: result)
        }
    }

    private func stepExpectingDone(_ statement: OpaquePointer, operation: String) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw sqliteFailure(operation: operation, code: result)
        }
    }

    private func sqliteFailure(operation: String, code: Int32) -> SQLiteEventJournalError {
        Self.classifiedSQLiteFailure(
            operation: operation,
            code: code,
            message: connection.withLock { Self.errorMessage(from: $0) }
        )
    }

    private static func classifiedSQLiteFailure(
        operation: String,
        code: Int32,
        database: OpaquePointer
    ) -> SQLiteEventJournalError {
        classifiedSQLiteFailure(
            operation: operation,
            code: code,
            message: errorMessage(from: database)
        )
    }

    private static func classifiedSQLiteFailure(
        operation: String,
        code: Int32,
        message: String
    ) -> SQLiteEventJournalError {
        let primaryCode = code & 0xFF
        switch primaryCode {
        case SQLITE_FULL:
            return .diskFull(operation: operation)
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            return .databaseCorrupt
        default:
            return .sqliteFailure(operation: operation, code: code, message: message)
        }
    }

    private func readInt32Pragma(_ sql: String) throws -> Int32 {
        try withStatement(sql, operation: "read SQLite pragma") { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW,
                  sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
                throw sqliteFailure(operation: "step SQLite pragma", code: result)
            }
            return sqlite3_column_int(statement, 0)
        }
    }

    private func readText(
        from statement: OpaquePointer,
        column: Int32,
        field: String
    ) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let bytes = sqlite3_column_text(statement, column) else {
            throw SQLiteEventJournalError.corruptStoredValue(field: field)
        }

        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    private func calibrationCoverage(
        _ value: String,
        field: String
    ) throws -> CalibrationCoverage {
        switch value {
        case "complete":
            return .complete
        case "partial":
            return .partial
        default:
            throw SQLiteEventJournalError.corruptStoredValue(field: field)
        }
    }

    private func readOptionalText(
        from statement: OpaquePointer,
        column: Int32,
        field: String
    ) throws -> String? {
        if sqlite3_column_type(statement, column) == SQLITE_NULL {
            return nil
        }
        return try readText(from: statement, column: column, field: field)
    }

    private func readData(
        from statement: OpaquePointer,
        column: Int32,
        field: String
    ) throws -> Data {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB else {
            throw SQLiteEventJournalError.corruptStoredValue(field: field)
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, count <= WatchedScopeBookmark.maximumBookmarkByteCount,
              let bytes = sqlite3_column_blob(statement, column) else {
            throw SQLiteEventJournalError.corruptStoredValue(field: field)
        }
        return Data(bytes: bytes, count: count)
    }

    private func readCursor(
        from statement: OpaquePointer,
        column: Int32,
        field: String
    ) throws -> EventJournalCursor {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB else {
            throw SQLiteEventJournalError.corruptStoredValue(field: field)
        }

        let count = Int(sqlite3_column_bytes(statement, column))
        guard count == 8, let bytes = sqlite3_column_blob(statement, column) else {
            throw SQLiteEventJournalError.invalidCursorEncoding(
                field: field,
                actualByteCount: count
            )
        }

        let buffer = UnsafeRawBufferPointer(start: bytes, count: count)
        var rawValue: UInt64 = 0
        for byte in buffer {
            rawValue = (rawValue << 8) | UInt64(byte)
        }
        return EventJournalCursor(rawValue)
    }

    private func readOptionalCursor(
        from statement: OpaquePointer,
        column: Int32,
        field: String
    ) throws -> EventJournalCursor? {
        if sqlite3_column_type(statement, column) == SQLITE_NULL {
            return nil
        }
        return try readCursor(from: statement, column: column, field: field)
    }

    private func readUInt64(
        from statement: OpaquePointer,
        column: Int32,
        field: String
    ) throws -> UInt64 {
        try readCursor(from: statement, column: column, field: field).rawValue
    }

    private func readOptionalByteCount(
        from statement: OpaquePointer,
        column: Int32,
        field: String
    ) throws -> ByteCount? {
        if sqlite3_column_type(statement, column) == SQLITE_NULL {
            return nil
        }
        guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else {
            throw SQLiteEventJournalError.corruptStoredValue(field: field)
        }
        let value = sqlite3_column_int64(statement, column)
        do {
            return try ByteCount(value)
        } catch {
            throw SQLiteEventJournalError.corruptStoredValue(field: field)
        }
    }

    private func readRequiredByteCount(
        from statement: OpaquePointer,
        column: Int32,
        field: String
    ) throws -> ByteCount {
        guard let value = try readOptionalByteCount(
            from: statement,
            column: column,
            field: field
        ) else {
            throw SQLiteEventJournalError.corruptStoredValue(field: field)
        }
        return value
    }

    private func readNonnegativeInt64(
        from statement: OpaquePointer,
        column: Int32,
        field: String
    ) throws -> Int64 {
        guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else {
            throw SQLiteEventJournalError.corruptStoredValue(field: field)
        }
        let value = sqlite3_column_int64(statement, column)
        guard value >= 0 else {
            throw SQLiteEventJournalError.corruptStoredValue(field: field)
        }
        return value
    }

    private func readPositiveInt(
        from statement: OpaquePointer,
        column: Int32,
        field: String
    ) throws -> Int {
        let value = try readNonnegativeInt64(
            from: statement,
            column: column,
            field: field
        )
        guard value > 0, value <= Int64(Int.max) else {
            throw SQLiteEventJournalError.corruptStoredValue(field: field)
        }
        return Int(value)
    }

    private func readDate(
        from statement: OpaquePointer,
        column: Int32,
        field: String
    ) throws -> Date {
        guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else {
            throw SQLiteEventJournalError.corruptStoredValue(field: field)
        }
        let milliseconds = sqlite3_column_int64(statement, column)
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    private func readOptionalUUID(
        from statement: OpaquePointer,
        column: Int32,
        field: String
    ) throws -> UUID? {
        guard let rawValue = try readOptionalText(
            from: statement,
            column: column,
            field: field
        ) else {
            return nil
        }
        guard let value = UUID(uuidString: rawValue) else {
            throw SQLiteEventJournalError.corruptStoredValue(field: field)
        }
        return value
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }

    private static func encode(_ cursor: EventJournalCursor) -> [UInt8] {
        encode(cursor.rawValue)
    }

    private static func encode(_ rawValue: UInt64) -> [UInt8] {
        (0..<8).map { offset in
            let shift = UInt64((7 - offset) * 8)
            return UInt8(truncatingIfNeeded: rawValue >> shift)
        }
    }

    private static func errorMessage(from database: OpaquePointer?) -> String {
        guard let database else {
            return "SQLite did not provide a database handle."
        }
        return String(cString: sqlite3_errmsg(database))
    }
}

private struct ScanRunContext {
    let streamID: EventStreamID
    let regionPath: DirtyRegionPath
    let revision: DirtyRegionRevision
    let state: String
}

private struct StoredAuthorizedBaselineHeader {
    let startedAt: Date
    let committedAt: Date
    let appVersion: String
    let schemaVersion: Int
    let volumeObservedAt: Date
    let volumeUUID: UUID?
    let volumeTotalBytes: ByteCount?
    let volumeAvailableBytes: ByteCount?
    let volumeImportantAvailableBytes: ByteCount?
    let rootCount: Int
}

private extension CalibrationCoverage {
    var storageValue: String {
        switch self {
        case .complete: "complete"
        case .partial: "partial"
        }
    }
}

enum SQLiteEventJournalTestFailurePoint: Sendable, Equatable {
    case afterDirtyRegionsBeforeCheckpoint
    case afterRecoveryWorkBeforeCheckpointInvalidation
    case afterExpiredDeletedNodesBeforeBaselines
    case beforeMigrationCommit(version: Int32)
}

public enum SQLiteEventJournalError: Error, Sendable, Equatable {
    case invalidDatabaseLocation
    case openFailed(code: Int32, message: String)
    case databaseClosed
    case databaseCorrupt
    case diskFull(operation: String)
    case migrationFailed(fromVersion: Int32, targetVersion: Int32)
    case unsupportedSchemaVersion(Int32)
    case cursorRegression(stored: UInt64, attempted: UInt64)
    case revisionOverflow(path: String)
    case scanRunNotFound(String)
    case scanRunNotRunning(String)
    case scanRunContextMismatch(String)
    case aggregateOutsideScanRegion(String)
    case incompleteReportCannotFinalize
    case stagedDirectoryCountMismatch(expected: Int64, actual: Int64)
    case dirtyRevisionChangedDuringFinalization
    case invalidCursorEncoding(field: String, actualByteCount: Int)
    case corruptStoredValue(field: String)
    case sqliteFailure(operation: String, code: Int32, message: String)
    case rollbackFailed(original: String, rollback: String)
    case injectedFailure
}
