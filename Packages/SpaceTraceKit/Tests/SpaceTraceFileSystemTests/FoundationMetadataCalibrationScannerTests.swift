import Foundation
import Testing
import SpaceTraceApplication
@testable import SpaceTraceFileSystem

struct FoundationMetadataCalibrationScannerTests {
    @Test("The production adapter scans only an isolated temporary fixture")
    func scansTemporaryFixtureWithFoundationAdapter() async throws {
        let fileManager = FileManager.default
        let fixture = fileManager.temporaryDirectory
            .appendingPathComponent("SpaceTraceScannerTests-\(UUID().uuidString)", isDirectory: true)
        let nested = fixture.appendingPathComponent("nested", isDirectory: true)
        let rootFile = fixture.appendingPathComponent("root.bin", isDirectory: false)
        let nestedFile = nested.appendingPathComponent("nested.bin", isDirectory: false)
        let link = fixture.appendingPathComponent("nested-link", isDirectory: false)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: fixture) }
        try Data(repeating: 0xA5, count: 17).write(to: rootFile)
        try Data(repeating: 0x5A, count: 29).write(to: nestedFile)
        try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: "nested")

        let root = try DirtyRegionPath(fixture.standardizedFileURL.path)
        let nestedPath = try DirtyRegionPath(nested.standardizedFileURL.path)
        let collector = AggregateCollector()
        let result = try await FoundationMetadataCalibrationScanner().scanHistorical(
            try request(root: root)
        ) { batch in
            await collector.append(batch)
        }

        let report = result.report
        let evidence = try #require(result.evidence)
        let aggregates = await collector.aggregates
        let rootAggregate = try #require(aggregates.first { $0.path == root })
        #expect(report.coverage == .complete)
        #expect(report.entriesVisited == 5)
        #expect(report.directoriesStaged == 2)
        #expect(aggregates.count == 2)
        #expect(rootAggregate.logicalBytes?.value == 52)
        #expect(rootAggregate.allocatedBytes != nil)
        #expect(rootAggregate.descendantCount == 4)
        #expect(aggregates.contains { $0.path.rawValue.hasSuffix("root.bin") } == false)
        #expect(aggregates.contains { $0.path.rawValue.hasSuffix("nested.bin") } == false)
        #expect(evidence.rootPath == root)
        #expect(evidence.directories.count == 2)
        let rootObservation = try #require(evidence.directories.first { $0.path == root })
        let nestedObservation = try #require(evidence.directories.first { $0.path == nestedPath })
        #expect(rootObservation.parentPath == nil)
        #expect(rootObservation.logicalBytes == rootAggregate.logicalBytes)
        #expect(rootObservation.allocatedBytes == rootAggregate.allocatedBytes)
        #expect(rootObservation.directChildrenCoverage == .complete)
        #expect(rootObservation.objectIdentity != nil)
        #expect(rootObservation.objectIdentity?.linkStatus == .unknown)
        #expect(nestedObservation.parentPath == root)
    }

    @Test("Directory aggregates contain no leaf paths and deduplicate hard-link allocation")
    func aggregatesMetadataOnly() async throws {
        let root = try DirtyRegionPath("/fixture")
        let subdirectory = try DirtyRegionPath("/fixture/subdirectory")
        let firstFile = try DirtyRegionPath("/fixture/a.bin")
        let linkedFile = try DirtyRegionPath("/fixture/subdirectory/a-link.bin")
        let identity = MetadataFileIdentity(volume: "volume-a", file: "inode-1")
        let source = FixtureMetadataSource(
            metadata: [
                root: directory(volume: "volume-a"),
                subdirectory: directory(volume: "volume-a"),
                firstFile: file(logical: 10, allocated: 8, identity: identity),
                linkedFile: file(logical: 10, allocated: 8, identity: identity),
            ],
            children: [
                root: [subdirectory, firstFile],
                subdirectory: [linkedFile],
            ]
        )
        let collector = AggregateCollector()
        let report = try await scanner(source).scan(try request(root: root)) { batch in
            await collector.append(batch)
        }

        let aggregates = await collector.aggregates
        let rootAggregate = try #require(aggregates.first { $0.path == root })
        let childAggregate = try #require(aggregates.first { $0.path == subdirectory })
        #expect(report.coverage == .complete)
        #expect(report.entriesVisited == 4)
        #expect(aggregates.count == 2)
        #expect(rootAggregate.logicalBytes?.value == 20)
        #expect(rootAggregate.allocatedBytes?.value == 8)
        #expect(rootAggregate.descendantCount == 3)
        #expect(childAggregate.logicalBytes?.value == 10)
        #expect(childAggregate.allocatedBytes?.value == 0)
    }

    @Test("Symbolic links are counted as objects and never traversed")
    func doesNotFollowSymbolicLinks() async throws {
        let root = try DirtyRegionPath("/fixture")
        let link = try DirtyRegionPath("/fixture/link")
        let source = FixtureMetadataSource(
            metadata: [
                root: directory(volume: "volume-a"),
                link: MetadataEntry(
                    kind: .symbolicLink,
                    logicalBytes: 5,
                    allocatedBytes: 8,
                    volumeIdentity: "volume-a",
                    fileIdentity: nil
                ),
            ],
            children: [root: [link]],
            childErrors: [link: .metadataUnavailable]
        )
        let collector = AggregateCollector()
        let report = try await scanner(source).scan(try request(root: root)) { batch in
            await collector.append(batch)
        }

        let aggregate = try #require(await collector.aggregates.first)
        #expect(report.coverage == .complete)
        #expect(aggregate.logicalBytes?.value == 5)
        #expect(aggregate.allocatedBytes?.value == 8)
        #expect(aggregate.descendantCount == 1)
    }

    @Test("A different mounted volume is not traversed and lowers coverage")
    func stopsAtMountBoundary() async throws {
        let root = try DirtyRegionPath("/fixture")
        let mounted = try DirtyRegionPath("/fixture/mounted")
        let source = FixtureMetadataSource(
            metadata: [
                root: directory(volume: "volume-a"),
                mounted: directory(volume: "volume-b"),
            ],
            children: [root: [mounted]],
            childErrors: [mounted: .metadataUnavailable]
        )
        let collector = AggregateCollector()
        let report = try await scanner(source).scan(try request(root: root)) { batch in
            await collector.append(batch)
        }

        #expect(report.coverage == .partial)
        #expect(report.gaps == [CalibrationGap(path: mounted, reason: .mountBoundary)])
        #expect(await collector.aggregates.count == 1)
    }

    @Test("Permission loss is coverage evidence and never an empty-directory claim")
    func recordsPermissionGap() async throws {
        let root = try DirtyRegionPath("/fixture")
        let protected = try DirtyRegionPath("/fixture/protected")
        let source = FixtureMetadataSource(
            metadata: [root: directory(volume: "volume-a")],
            children: [root: [protected]],
            metadataErrors: [protected: .permissionDenied]
        )
        let collector = AggregateCollector()
        let report = try await scanner(source).scan(try request(root: root)) { batch in
            await collector.append(batch)
        }

        let aggregate = try #require(await collector.aggregates.first)
        #expect(report.coverage == .partial)
        #expect(report.gaps == [CalibrationGap(path: protected, reason: .permissionDenied)])
        #expect(aggregate.coverage == .partial)
        #expect(aggregate.descendantCount == 0)
    }

    @Test("The entry budget produces a partial staged root and bounded work")
    func enforcesEntryBudget() async throws {
        let root = try DirtyRegionPath("/fixture")
        let child = try DirtyRegionPath("/fixture/child")
        let budget = try CalibrationScanBudget(
            maximumEntries: 1,
            maximumDepth: 10,
            maximumDurationMilliseconds: 1_000,
            stageBatchSize: 1,
            yieldEveryEntries: 1
        )
        let source = FixtureMetadataSource(
            metadata: [
                root: directory(volume: "volume-a"),
                child: file(logical: 10, allocated: 8),
            ],
            children: [root: [child]]
        )
        let collector = AggregateCollector()
        let report = try await scanner(source).scan(
            try request(root: root, budget: budget)
        ) { batch in
            await collector.append(batch)
        }

        #expect(report.coverage == .partial)
        #expect(report.entriesVisited == 1)
        #expect(report.gaps == [CalibrationGap(path: root, reason: .entryBudgetExceeded)])
        #expect(await collector.batchSizes == [1])
    }

    @Test("Cooperative cancellation stops enumeration and publishes no final report")
    func observesCancellation() async throws {
        let root = try DirtyRegionPath("/fixture")
        let cancellingFile = try DirtyRegionPath("/fixture/cancel")
        let source = FixtureMetadataSource(
            metadata: [
                root: directory(volume: "volume-a"),
                cancellingFile: file(logical: 1, allocated: 1),
            ],
            children: [root: [cancellingFile]],
            cancelAtMetadataPath: cancellingFile
        )

        do {
            _ = try await scanner(source).scan(try request(root: root)) { _ in }
            Issue.record("Expected cooperative cancellation.")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func scanner(_ source: FixtureMetadataSource) -> FoundationMetadataCalibrationScanner {
        FoundationMetadataCalibrationScanner(source: source)
    }

    private func request(
        root: DirtyRegionPath,
        budget: CalibrationScanBudget = .incremental
    ) throws -> CalibrationRequest {
        let region = try DirtyRegion(
            path: root,
            reasons: [.requiresCalibration],
            maximumCursor: EventJournalCursor(1)
        )
        return CalibrationRequest(
            streamID: try EventStreamID("volume-a:generation-1"),
            workItem: DirtyRegionWorkItem(
                region: region,
                revision: try DirtyRegionRevision(1)
            ),
            budget: budget
        )
    }
}

private actor AggregateCollector {
    private(set) var aggregates: [DirectoryMetadataAggregate] = []
    private(set) var batchSizes: [Int] = []

    func append(_ batch: [DirectoryMetadataAggregate]) {
        batchSizes.append(batch.count)
        aggregates.append(contentsOf: batch)
    }
}

private struct FixtureMetadataSource: MetadataTreeSource {
    let metadataByPath: [DirtyRegionPath: MetadataEntry]
    let childrenByPath: [DirtyRegionPath: [DirtyRegionPath]]
    let metadataErrors: [DirtyRegionPath: MetadataTreeSourceError]
    let childErrors: [DirtyRegionPath: MetadataTreeSourceError]
    let cancelAtMetadataPath: DirtyRegionPath?

    init(
        metadata: [DirtyRegionPath: MetadataEntry],
        children: [DirtyRegionPath: [DirtyRegionPath]],
        metadataErrors: [DirtyRegionPath: MetadataTreeSourceError] = [:],
        childErrors: [DirtyRegionPath: MetadataTreeSourceError] = [:],
        cancelAtMetadataPath: DirtyRegionPath? = nil
    ) {
        metadataByPath = metadata
        childrenByPath = children
        self.metadataErrors = metadataErrors
        self.childErrors = childErrors
        self.cancelAtMetadataPath = cancelAtMetadataPath
    }

    func metadata(at path: DirtyRegionPath) throws -> MetadataEntry {
        if path == cancelAtMetadataPath {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        if let error = metadataErrors[path] { throw error }
        guard let metadata = metadataByPath[path] else {
            throw MetadataTreeSourceError.entryDisappeared
        }
        return metadata
    }

    func children(of directory: DirtyRegionPath, limit: Int) throws -> MetadataChildren {
        if let error = childErrors[directory] { throw error }
        let children = childrenByPath[directory] ?? []
        return MetadataChildren(
            entries: Array(children.prefix(max(0, limit))),
            wasTruncated: children.count > max(0, limit)
        )
    }
}

private func directory(volume: String) -> MetadataEntry {
    MetadataEntry(
        kind: .directory,
        logicalBytes: nil,
        allocatedBytes: nil,
        volumeIdentity: volume,
        fileIdentity: nil
    )
}

private func file(
    logical: Int64,
    allocated: Int64,
    identity: MetadataFileIdentity? = nil
) -> MetadataEntry {
    MetadataEntry(
        kind: .file,
        logicalBytes: logical,
        allocatedBytes: allocated,
        volumeIdentity: identity?.volume ?? "volume-a",
        fileIdentity: identity
    )
}
