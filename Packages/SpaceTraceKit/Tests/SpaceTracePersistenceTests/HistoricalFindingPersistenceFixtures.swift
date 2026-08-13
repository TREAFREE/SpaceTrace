import Foundation
import SQLite3
import SpaceTraceApplication
import SpaceTraceAttribution
import SpaceTraceDomain
import Testing
@testable import SpaceTracePersistence

struct HistoricalLedgerTestFixture {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpaceTrace-historical-ledger-\(UUID().uuidString)",
            isDirectory: true
        )
        databaseURL = directoryURL.appendingPathComponent("SpaceTrace.sqlite")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func count(_ table: String) throws -> Int64 {
        try int("SELECT count(*) FROM \(quotedIdentifier(table))")
    }

    func int(_ sql: String) throws -> Int64 {
        let database = try open()
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw HistoricalLedgerFixtureError.sqlite(
                String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw HistoricalLedgerFixtureError.sqlite(
                String(cString: sqlite3_errmsg(database))
            )
        }
        return sqlite3_column_int64(statement, 0)
    }

    func rows(_ sql: String) throws -> [[String]] {
        let database = try open()
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw HistoricalLedgerFixtureError.sqlite(
                String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else {
                throw HistoricalLedgerFixtureError.sqlite(
                    String(cString: sqlite3_errmsg(database))
                )
            }
            result.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map(String.init(cString:)) ?? "NULL"
            })
        }
    }

    func execute(_ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            throw HistoricalLedgerFixtureError.sqlite("open")
        }
        defer { sqlite3_close_v2(database) }
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let text = message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            if let message { sqlite3_free(message) }
            throw HistoricalLedgerFixtureError.sqlite(text)
        }
    }

    private func open() throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            throw HistoricalLedgerFixtureError.sqlite("open")
        }
        return database
    }

    private func quotedIdentifier(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

struct HistoricalLedgerPreparedRun {
    let streamID: EventStreamID
    let workItem: DirtyRegionWorkItem
    let runID: CalibrationRunID
    let report: CalibrationReport
    let request: HistoricalCalibrationFinalizationRequest
}

func prepareHistoricalLedgerRun(
    repository: SQLiteEventJournalRepository,
    streamName: String = "historical-ledger-stream",
    rootPath: String = "/Fixtures",
    logicalRootBytes: Int64 = 100,
    allocatedRootBytes: Int64 = 80,
    child: HistoricalLedgerChildState = .present(logical: 40, allocated: 32),
    observedAtMilliseconds: Int64 = 2_000_000_000_000,
    candidateOrderReversed: Bool = false
) async throws -> HistoricalLedgerPreparedRun {
    let streamID = try EventStreamID(streamName)
    let root = try DirtyRegionPath(rootPath)
    let dirty = try DirtyRegion(
        path: root,
        reasons: [.contentModified, .requiresCalibration],
        maximumCursor: EventJournalCursor(UInt64(observedAtMilliseconds))
    )
    try await repository.markDirty(streamID: streamID, regions: [dirty])
    let workItem = try #require(
        try await repository.pendingDirtyWork(for: streamID, limit: 1).first
    )
    let runID = try await repository.beginCalibration(
        CalibrationRequest(streamID: streamID, workItem: workItem)
    )

    var aggregates = [
        try DirectoryMetadataAggregate(
            path: root,
            logicalBytes: ByteCount(logicalRootBytes),
            allocatedBytes: ByteCount(allocatedRootBytes),
            descendantCount: child.isPresent ? 1 : 0,
            coverage: .complete
        ),
    ]
    if case let .present(logical, allocated) = child {
        aggregates.append(
            try DirectoryMetadataAggregate(
                path: DirtyRegionPath(rootPath + "/Child"),
                logicalBytes: ByteCount(logical),
                allocatedBytes: ByteCount(allocated),
                descendantCount: 0,
                coverage: .complete
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
    var nodes = [
        try historicalLedgerNode(
            subject: "root",
            parent: nil,
            location: "location-root",
            path: rootPath,
            displayName: "Fixtures",
            state: .present(
                logicalBytes: ByteCount(logicalRootBytes),
                allocatedBytes: ByteCount(allocatedRootBytes),
                measurementCoverage: .complete
            ),
            childrenCoverage: .complete,
            observedAtMilliseconds: observedAtMilliseconds
        ),
    ]
    switch child {
    case let .present(logical, allocated):
        nodes.append(
            try historicalLedgerNode(
                subject: "child",
                parent: "root",
                location: "location-child",
                path: rootPath + "/Child",
                displayName: "Child",
                state: .present(
                    logicalBytes: ByteCount(logical),
                    allocatedBytes: ByteCount(allocated),
                    measurementCoverage: .complete
                ),
                childrenCoverage: .complete,
                observedAtMilliseconds: observedAtMilliseconds + 1
            )
        )
    case .absent:
        nodes.append(
            try historicalLedgerNode(
                subject: "child",
                parent: "root",
                location: "location-child",
                path: rootPath + "/Child",
                displayName: "Child",
                state: .absent,
                childrenCoverage: .unknown,
                observedAtMilliseconds: observedAtMilliseconds + 1,
                classification: nil
            )
        )
    case let .unknown(reason):
        nodes.append(
            try historicalLedgerNode(
                subject: "child",
                parent: "root",
                location: "location-child",
                path: rootPath + "/Child",
                displayName: "Child",
                state: .unknown(reason),
                childrenCoverage: .unknown,
                observedAtMilliseconds: observedAtMilliseconds + 1,
                classification: nil
            )
        )
    case .omitted:
        break
    }
    if candidateOrderReversed { nodes.reverse() }
    let observation = try HistoricalPairedObservationCandidate(
        rootSubjectID: SubjectID("root"),
        rootPath: rootPath,
        nodes: nodes,
        scopeID: ScopeID("scope-fixture"),
        volumeID: ObservationVolumeID("volume-fixture"),
        mountGenerationID: ObservationMountGenerationID("mount-fixture"),
        coverageEpochID: ObservationCoverageEpochID("coverage-fixture"),
        pathSemanticsVersion: ObservationSemanticsVersion(1),
        measurementSemanticsVersion: ObservationSemanticsVersion(1)
    )
    let request = try HistoricalCalibrationFinalizationRequest(
        runID: runID,
        report: report,
        workItem: workItem,
        streamID: streamID,
        observation: observation
    )
    return HistoricalLedgerPreparedRun(
        streamID: streamID,
        workItem: workItem,
        runID: runID,
        report: report,
        request: request
    )
}

enum HistoricalLedgerChildState {
    case present(logical: Int64, allocated: Int64)
    case absent
    case unknown(ObservationUnavailabilityReason)
    case omitted

    var isPresent: Bool {
        if case .present = self { return true }
        return false
    }
}

func historicalLedgerNode(
    subject: String,
    parent: String?,
    location: String,
    path: String,
    displayName: String,
    state: HistoricalPairedObservationStateCandidate,
    childrenCoverage: ObservationCoverage,
    observedAtMilliseconds: Int64,
    classification: VersionedAttributionDecision? = historicalLedgerNoMatchDecision()
) throws -> HistoricalPairedObservationNodeCandidate {
    try HistoricalPairedObservationNodeCandidate(
        subjectID: SubjectID(subject),
        identityBasis: .normalizedPath,
        parentSubjectID: try parent.map(SubjectID.init),
        locationID: ObservationLocationID(location),
        path: path,
        displayName: displayName,
        observedAt: ObservationInstant(millisecondsSince1970: observedAtMilliseconds),
        state: state,
        directChildrenCoverage: childrenCoverage,
        classification: classification,
        stableIdentityEvidence: nil
    )
}

func historicalLedgerNoMatchDecision() -> VersionedAttributionDecision {
    try! VersionedAttributionDecision(
        catalogVersion: AttributionCatalogVersion(1),
        result: .unknown(.noMatchingRule)
    )
}

private enum HistoricalLedgerFixtureError: Error {
    case sqlite(String)
}
