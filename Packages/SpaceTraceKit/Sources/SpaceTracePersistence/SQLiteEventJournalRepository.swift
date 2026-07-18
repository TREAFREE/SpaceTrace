import Foundation
import SQLite3
import SpaceTraceApplication
import Synchronization

/// A dependency-free SQLite prototype for ADR-004. The actor is the sole
/// owner of the connection and serializes every transaction and query.
public actor SQLiteEventJournalRepository: EventJournalRepository {
    private static let schemaVersion: Int32 = 2

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
            return
        case 0:
            try migrateToVersionOne(database)
            try migrateToVersionTwo(database)
        case 1:
            try migrateToVersionTwo(database)
        default:
            throw SQLiteEventJournalError.unsupportedSchemaVersion(currentVersion)
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

enum SQLiteEventJournalTestFailurePoint: Sendable, Equatable {
    case afterDirtyRegionsBeforeCheckpoint
}

public enum SQLiteEventJournalError: Error, Sendable, Equatable {
    case invalidDatabaseLocation
    case openFailed(code: Int32, message: String)
    case databaseClosed
    case unsupportedSchemaVersion(Int32)
    case cursorRegression(stored: UInt64, attempted: UInt64)
    case revisionOverflow(path: String)
    case invalidCursorEncoding(field: String, actualByteCount: Int)
    case corruptStoredValue(field: String)
    case sqliteFailure(operation: String, code: Int32, message: String)
    case rollbackFailed(original: String, rollback: String)
    case injectedFailure
}
