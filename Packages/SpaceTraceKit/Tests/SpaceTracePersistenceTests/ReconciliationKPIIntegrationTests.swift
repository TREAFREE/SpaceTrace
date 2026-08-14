import Darwin
import Foundation
import SpaceTraceApplication
import SpaceTraceDomain
import SpaceTraceFileSystem
import Testing
@testable import SpaceTracePersistence

extension Tag {
    @Tag static var apfsReconciliation: Self
}

@Suite(
    "FR-004 reconciliation KPI integration",
    .serialized,
    .tags(.apfsReconciliation)
)
struct ReconciliationKPIIntegrationTests {
    private static let fiveGiB = Int64(5) * 1_073_741_824

    @Test(
        "A continuity gap followed by an allocated 5 GiB change is recovered in the exact subtree",
        .enabled(
            if: ProcessInfo.processInfo.environment[
                "SPACETRACE_RUN_APFS_RECONCILIATION_TESTS"
            ] == "1"
        ),
        .timeLimit(.minutes(5))
    )
    func recoversAllocatedFiveGiBChangeAfterContinuityLoss() async throws {
        let fixture = try ReconciliationKPIFixture()
        defer { fixture.remove() }
        let capacity = try fixture.root.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        let availableCapacity = capacity.volumeAvailableCapacityForImportantUsage
            ?? capacity.volumeAvailableCapacity.map(Int64.init)
        guard let availableCapacity,
              availableCapacity >= Self.fiveGiB + 3 * 1_073_741_824 else {
            throw ReconciliationKPIFixtureError.insufficientCapacity
        }
        let targetURL = fixture.watchedRoot.appendingPathComponent(
            "KPI02Target",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: targetURL,
            withIntermediateDirectories: false
        )

        let repository = try SQLiteEventJournalRepository(
            databaseURL: fixture.databaseURL
        )
        let root = try DirtyRegionPath(fixture.watchedRoot.standardizedFileURL.path)
        let target = try DirtyRegionPath(targetURL.standardizedFileURL.path)
        let streamID = try EventStreamID("reconciliation-kpi-integration")
        let scopeID = try ScopeID("reconciliation-kpi-scope")
        let pipeline = FileSystemCalibrationPipeline(
            streamID: streamID,
            watchRoot: root,
            repository: repository,
            scanner: FoundationMetadataCalibrationScanner(),
            historicalContext: HistoricalCalibrationContext(
                scopeID: scopeID,
                volumeID: try ObservationVolumeID("reconciliation-kpi-volume"),
                mountGenerationID: try ObservationMountGenerationID(
                    "reconciliation-kpi-mount"
                ),
                coverageEpochID: try ObservationCoverageEpochID(
                    "reconciliation-kpi-coverage"
                ),
                homeDirectoryPath: nil
            ),
            historicalFindingProjector: HistoricalFindingProjector(
                repository: repository
            ),
            scanBudget: try CalibrationScanBudget(
                maximumEntries: 64,
                maximumDepth: 8,
                maximumDurationMilliseconds: 120_000,
                stageBatchSize: 8,
                yieldEveryEntries: 8
            )
        )

        try await pipeline.ingest([
            try reconciliationInvalidation(
                path: root.rawValue,
                cursor: 1
            ),
        ])
        #expect(try await pipeline.calibratePending(limit: 1) == 1)

        let payloadURL = targetURL.appendingPathComponent(
            "allocated-five-gib.fixture",
            isDirectory: false
        )
        try allocateFile(at: payloadURL, byteCount: Self.fiveGiB)
        let allocatedBytes = try allocatedByteCount(at: payloadURL)
        #expect(allocatedBytes >= Self.fiveGiB)

        let gap = FSEventObservation(
            path: nil,
            eventID: FSEventID(rawValue: 2),
            reasons: [.eventsDroppedByKernel],
            rawFlags: 0
        )
        try await pipeline.ingest([
            try #require(try FSEventInvalidationMapper().map(gap)),
        ])

        let dirty = try #require(
            try await repository.dirtyRegions(for: streamID).first
        )
        #expect(dirty.path == root)
        #expect(dirty.maximumCursor == nil)
        #expect(dirty.reasons.contains(.requiresCalibration))
        #expect(try await repository.checkpoint(for: streamID) == EventJournalCursor(1))

        #expect(try await pipeline.calibratePending(limit: 1) == 1)
        #expect(try await repository.dirtyRegions(for: streamID).isEmpty)
        let findings = try await repository.effectiveHistoricalFindings(
            for: scopeID,
            through: try ObservationCommitSequence(4),
            limit: try HistoricalFindingQueryLimit(10)
        )
        let targetGrowth = try #require(findings.first { finding in
            finding.draft.kind == .growth
                && finding.draft.evidence.metric == .allocated
                && finding.draft.evidence.comparisonPath == target.rawValue
        })
        #expect(targetGrowth.draft.inclusiveDelta.bytes >= Self.fiveGiB)
        let rankingContribution = try #require(
            targetGrowth.draft.rankingContribution
        )
        #expect(rankingContribution.bytes >= Self.fiveGiB)

        let baseline = try #require(
            try await repository.historicalObservationFrame(
                sequence: try ObservationCommitSequence(2)
            )
        )
        let comparison = try #require(
            try await repository.historicalObservationFrame(
                sequence: try ObservationCommitSequence(4)
            )
        )
        #expect(baseline.nodes.contains { $0.path == target.rawValue })
        #expect(comparison.nodes.contains { $0.path == target.rawValue })
        try await repository.close()
    }
}

private struct ReconciliationKPIFixture {
    let root: URL
    let watchedRoot: URL
    let databaseURL: URL

    init() throws {
        let fixtureParent: URL
        if let configuredParent = ProcessInfo.processInfo.environment[
            "SPACETRACE_RECONCILIATION_FIXTURE_PARENT"
        ] {
            fixtureParent = URL(
                fileURLWithPath: configuredParent,
                isDirectory: true
            ).standardizedFileURL
            let values = try fixtureParent.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ReconciliationKPIFixtureError.invalidFixtureParent
            }
        } else {
            fixtureParent = FileManager.default.temporaryDirectory
        }
        root = fixtureParent.appendingPathComponent(
            "SpaceTrace-Reconciliation-KPI-\(UUID().uuidString)",
            isDirectory: true
        )
        watchedRoot = root.appendingPathComponent("Watched", isDirectory: true)
        databaseURL = root.appendingPathComponent("Ledger.sqlite", isDirectory: false)
        try FileManager.default.createDirectory(
            at: watchedRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func reconciliationInvalidation(
    path: String,
    cursor: UInt64
) throws -> FileSystemInvalidation {
    try FileSystemInvalidation(
        path: path,
        cursor: EventJournalCursor(cursor),
        reasons: [.contentModified],
        itemKind: .directory
    )
}

private func allocateFile(at url: URL, byteCount: Int64) throws {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw ReconciliationKPIFixtureError.cannotCreateFile
    }
    let descriptor = open(url.path, O_RDWR | O_CLOEXEC)
    guard descriptor >= 0 else { throw ReconciliationKPIFixtureError.cannotOpenFile }
    defer { close(descriptor) }

    var allocation = fstore_t(
        fst_flags: UInt32(F_ALLOCATEALL),
        fst_posmode: F_PEOFPOSMODE,
        fst_offset: 0,
        fst_length: byteCount,
        fst_bytesalloc: 0
    )
    guard fcntl(descriptor, F_PREALLOCATE, &allocation) != -1,
          ftruncate(descriptor, off_t(byteCount)) == 0,
          fsync(descriptor) == 0 else {
        throw ReconciliationKPIFixtureError.cannotAllocateFile(errno)
    }
}

private func allocatedByteCount(at url: URL) throws -> Int64 {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
        throw ReconciliationKPIFixtureError.cannotReadAllocation(errno)
    }
    return Int64(metadata.st_blocks) * 512
}

private enum ReconciliationKPIFixtureError: Error {
    case insufficientCapacity
    case invalidFixtureParent
    case cannotCreateFile
    case cannotOpenFile
    case cannotAllocateFile(Int32)
    case cannotReadAllocation(Int32)
}
