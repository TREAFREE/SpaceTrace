import Foundation
import SQLite3
import SpaceTraceApplication
import Synchronization

/// A dependency-free SQLite prototype for ADR-004. The actor is the sole
/// owner of the connection and serializes every transaction and query.
public actor SQLiteEventJournalRepository: EventJournalRepository {
    private static let schemaVersion: Int32 = 1

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

            for region in batch.dirtyRegions {
                try upsert(region: region, streamID: batch.streamID)
            }

            try failIfRequested(at: .afterDirtyRegionsBeforeCheckpoint)
            try upsert(checkpoint: batch.checkpoint, streamID: batch.streamID)
            try execute("COMMIT TRANSACTION", operation: "commit event-journal transaction")
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
                        let cursor = try readCursor(
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
        default:
            throw SQLiteEventJournalError.unsupportedSchemaVersion(currentVersion)
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

    private func upsert(region: DirtyRegion, streamID: EventStreamID) throws {
        let sql = """
            INSERT INTO dirty_region(stream_id, path, reasons, maximum_cursor_be)
            VALUES(?1, ?2, ?3, ?4)
            ON CONFLICT(stream_id, path) DO UPDATE SET
                reasons = dirty_region.reasons | excluded.reasons,
                maximum_cursor_be = CASE
                    WHEN dirty_region.maximum_cursor_be < excluded.maximum_cursor_be
                        THEN excluded.maximum_cursor_be
                    ELSE dirty_region.maximum_cursor_be
                END
            """
        let cursorBytes = Self.encode(region.maximumCursor)

        try withStatement(sql, operation: "upsert dirty region") { statement in
            try streamID.rawValue.withCString { streamCString in
                try region.path.rawValue.withCString { pathCString in
                    try cursorBytes.withUnsafeBytes { cursorBuffer in
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
                        try stepExpectingDone(statement, operation: "write dirty region")
                    }
                }
            }
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

    private static func encode(_ cursor: EventJournalCursor) -> [UInt8] {
        (0..<8).map { offset in
            let shift = UInt64((7 - offset) * 8)
            return UInt8(truncatingIfNeeded: cursor.rawValue >> shift)
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
    case invalidCursorEncoding(field: String, actualByteCount: Int)
    case corruptStoredValue(field: String)
    case sqliteFailure(operation: String, code: Int32, message: String)
    case rollbackFailed(original: String, rollback: String)
    case injectedFailure
}
