import Foundation
import SQLite3
import SpaceTraceApplication
import SpaceTraceDomain
import Synchronization

/// A dependency-free SQLite prototype for ADR-004. The actor is the sole
/// owner of the connection and serializes every transaction and query.
public actor SQLiteEventJournalRepository: EventJournalRepository, ScopeMountGenerationRepository {
    private static let schemaVersion: Int32 = 4

    /// `Mutex` makes the non-Sendable C handle safe to release from the
    /// actor's nonisolated deinitializer. All operational access remains
    /// serialized by the actor itself.
    private let connection: Mutex<OpaquePointer?>
    private var injectedFailurePoint: SQLiteEventJournalTestFailurePoint?

    public init(databaseURL: URL) throws {
        try self.init(databaseURL: databaseURL, failurePoint: nil)
    }

    init(
        databaseURL: URL,
        failurePoint: SQLiteEventJournalTestFailurePoint?
    ) throws {
        guard databaseURL.isFileURL, databaseURL.path.isEmpty == false else {
            throw SQLiteEventJournalError.invalidDatabaseLocation
        }

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

        do {
            try Self.configureAndMigrate(openedDatabase)
        } catch {
            _ = sqlite3_close_v2(openedDatabase)
            throw error
        }

        connection = Mutex(openedDatabase)
        injectedFailurePoint = failurePoint
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
        let startedAt = Int64(Date().timeIntervalSince1970 * 1_000)
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
                        let coverage: CalibrationCoverage = coverageText == "complete" ? .complete : .partial
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

    private static func configureAndMigrate(_ database: OpaquePointer) throws {
        let timeoutResult = sqlite3_busy_timeout(database, 5_000)
        guard timeoutResult == SQLITE_OK else {
            throw SQLiteEventJournalError.sqliteFailure(
                operation: "configure busy timeout",
                code: timeoutResult,
                message: errorMessage(from: database)
            )
        }

        try execute(on: database, "PRAGMA journal_mode = WAL", operation: "enable WAL mode")
        try execute(on: database, "PRAGMA foreign_keys = ON", operation: "enable foreign keys")
        try execute(
            on: database,
            "PRAGMA synchronous = NORMAL",
            operation: "configure synchronous mode"
        )

        let currentVersion = try readSchemaVersion(from: database)

        switch currentVersion {
        case Self.schemaVersion:
            break
        case 0:
            try migrateToVersionOne(database)
            try migrateToVersionTwo(database)
            try migrateToVersionThree(database)
            try migrateToVersionFour(database)
        case 1:
            try migrateToVersionTwo(database)
            try migrateToVersionThree(database)
            try migrateToVersionFour(database)
        case 2:
            try migrateToVersionThree(database)
            try migrateToVersionFour(database)
        case 3:
            try migrateToVersionFour(database)
        default:
            throw SQLiteEventJournalError.unsupportedSchemaVersion(currentVersion)
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
            throw SQLiteEventJournalError.sqliteFailure(
                operation: "prepare schema-version query",
                code: prepareResult,
                message: errorMessage(from: database)
            )
        }
        defer {
            _ = sqlite3_finalize(statement)
        }

        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW else {
            throw SQLiteEventJournalError.sqliteFailure(
                operation: "step schema-version query",
                code: stepResult,
                message: errorMessage(from: database)
            )
        }

        return sqlite3_column_int(statement, 0)
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
                stream_id, path, reasons, maximum_cursor_be, revision_be
            )
            VALUES(?1, ?2, ?3, ?4, ?5)
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
            SET deleted = 1, last_scan_run_id = ?1
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
                descendant_count, coverage, last_scan_run_id, deleted
            )
            SELECT ?1, path, logical_bytes, allocated_bytes,
                descendant_count, coverage, scan_run_id, 0
            FROM scan_node_stage
            WHERE scan_run_id = ?2
            ON CONFLICT(stream_id, path) DO UPDATE SET
                logical_bytes = excluded.logical_bytes,
                allocated_bytes = excluded.allocated_bytes,
                descendant_count = excluded.descendant_count,
                coverage = excluded.coverage,
                last_scan_run_id = excluded.last_scan_run_id,
                deleted = 0
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
                    sqlite3_bind_text(statement, index, valueCString, -1, nil),
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

            throw SQLiteEventJournalError.sqliteFailure(
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
        .sqliteFailure(
            operation: operation,
            code: code,
            message: connection.withLock { Self.errorMessage(from: $0) }
        )
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
}

public enum SQLiteEventJournalError: Error, Sendable, Equatable {
    case invalidDatabaseLocation
    case openFailed(code: Int32, message: String)
    case databaseClosed
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
