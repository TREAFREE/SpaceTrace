import Foundation
import Darwin
import SpaceTraceApplication
import SpaceTraceDomain

public struct FoundationMetadataCalibrationScanner: CalibrationScanner {
    private let source: any MetadataTreeSource
    private let excludedPaths: Set<DirtyRegionPath>
    private let monotonicNanoseconds: @Sendable () -> UInt64

    public init(excludedPaths: [DirtyRegionPath] = []) {
        self.init(
            source: FoundationMetadataTreeSource(),
            excludedPaths: excludedPaths,
            monotonicNanoseconds: { DispatchTime.now().uptimeNanoseconds }
        )
    }

    init(
        source: any MetadataTreeSource,
        excludedPaths: [DirtyRegionPath] = [],
        monotonicNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.source = source
        self.excludedPaths = Set(excludedPaths)
        self.monotonicNanoseconds = monotonicNanoseconds
    }

    public func scan(
        _ request: CalibrationRequest,
        stage: @escaping @Sendable ([DirectoryMetadataAggregate]) async throws -> Void
    ) async throws -> CalibrationReport {
        let root = request.workItem.region.path
        let budget = request.budget
        let startedAt = monotonicNanoseconds()
        let durationLimit = budget.maximumDurationMilliseconds.multipliedReportingOverflow(
            by: 1_000_000
        )
        let maximumNanoseconds = durationLimit.overflow ? UInt64.max : durationLimit.partialValue

        var stack: [ScanWork] = [.visit(path: root, parent: nil, depth: 0)]
        var accumulators: [DirtyRegionPath: DirectoryAccumulator] = [:]
        var parentPaths: [DirtyRegionPath: DirtyRegionPath] = [:]
        var depths: [DirtyRegionPath: Int] = [:]
        var rootVolumeIdentity: String?
        var allocatedFileIdentities: Set<MetadataFileIdentity> = []
        var stagedBatch: [DirectoryMetadataAggregate] = []
        var gaps: [CalibrationGap] = []
        var entriesVisited: Int64 = 0
        var directoriesStaged: Int64 = 0
        var stoppedByBudget = false

        while let work = stack.popLast() {
            try Task.checkCancellation()

            if elapsedNanoseconds(since: startedAt) >= maximumNanoseconds {
                gaps.append(CalibrationGap(path: root, reason: .timeBudgetExceeded))
                stoppedByBudget = true
                break
            }

            switch work {
            case .visit(let path, let parent, let depth):
                guard isExcluded(path) == false else { continue }
                guard entriesVisited < Int64(budget.maximumEntries) else {
                    gaps.append(CalibrationGap(path: root, reason: .entryBudgetExceeded))
                    stoppedByBudget = true
                    break
                }
                entriesVisited += 1
                if entriesVisited % Int64(budget.yieldEveryEntries) == 0 {
                    await Task.yield()
                    try Task.checkCancellation()
                }

                let metadata: MetadataEntry
                do {
                    metadata = try source.metadata(at: path)
                } catch {
                    record(error, at: path, parent: parent, accumulators: &accumulators, gaps: &gaps)
                    continue
                }

                switch metadata.kind {
                case .directory:
                    guard depth <= budget.maximumDepth else {
                        markPartial(parent, in: &accumulators)
                        gaps.append(CalibrationGap(path: path, reason: .depthBudgetExceeded))
                        continue
                    }

                    if depth == 0 {
                        guard let volumeIdentity = metadata.volumeIdentity else {
                            let aggregate = try DirectoryMetadataAggregate(
                                path: root,
                                logicalBytes: .zero,
                                allocatedBytes: .zero,
                                descendantCount: 0,
                                coverage: .partial
                            )
                            try await stage([aggregate])
                            return try CalibrationReport(
                                coverage: .partial,
                                entriesVisited: entriesVisited,
                                directoriesStaged: 1,
                                gaps: [CalibrationGap(path: root, reason: .metadataUnavailable)]
                            )
                        }
                        rootVolumeIdentity = volumeIdentity
                    } else if metadata.volumeIdentity == nil
                                || metadata.volumeIdentity != rootVolumeIdentity {
                        markPartial(parent, in: &accumulators)
                        gaps.append(CalibrationGap(path: path, reason: .mountBoundary))
                        continue
                    }

                    accumulators[path] = DirectoryAccumulator()
                    depths[path] = depth
                    if let parent { parentPaths[path] = parent }

                    let childPage: MetadataChildren
                    do {
                        let remainingEntryBudget = budget.maximumEntries - Int(entriesVisited)
                        childPage = try source.children(
                            of: path,
                            limit: remainingEntryBudget
                        )
                    } catch {
                        record(error, at: path, parent: path, accumulators: &accumulators, gaps: &gaps)
                        stack.append(.finish(path: path, parent: parent))
                        continue
                    }

                    var children: [DirtyRegionPath] = []
                    children.reserveCapacity(childPage.entries.count)
                    for child in childPage.entries {
                        guard contains(child, in: path), child != path else {
                            markPartial(path, in: &accumulators)
                            gaps.append(CalibrationGap(path: child, reason: .metadataUnavailable))
                            continue
                        }
                        children.append(child)
                    }
                    children.sort { $0.rawValue < $1.rawValue }
                    if childPage.wasTruncated {
                        markPartial(path, in: &accumulators)
                        gaps.append(CalibrationGap(path: path, reason: .entryBudgetExceeded))
                    }

                    stack.append(.finish(path: path, parent: parent))
                    for child in children.reversed() {
                        stack.append(.visit(path: child, parent: path, depth: depth + 1))
                    }

                case .file, .symbolicLink, .other:
                    guard let parent else {
                        gaps.append(CalibrationGap(path: path, reason: .metadataUnavailable))
                        continue
                    }
                    add(
                        metadata,
                        at: path,
                        to: parent,
                        allocatedFileIdentities: &allocatedFileIdentities,
                        accumulators: &accumulators,
                        gaps: &gaps
                    )
                }

            case .finish(let path, let parent):
                guard let accumulator = accumulators.removeValue(forKey: path) else {
                    continue
                }
                let aggregate = try accumulator.aggregate(at: path)
                stagedBatch.append(aggregate)
                directoriesStaged += 1
                if let parent {
                    add(aggregate, to: parent, accumulators: &accumulators, gaps: &gaps)
                }
                if stagedBatch.count >= budget.stageBatchSize {
                    let outgoing = stagedBatch
                    stagedBatch.removeAll(keepingCapacity: true)
                    try await stage(outgoing)
                }
            }

            if stoppedByBudget { break }
        }

        if stoppedByBudget {
            for path in accumulators.keys.sorted(by: {
                (depths[$0] ?? 0) > (depths[$1] ?? 0)
            }) {
                guard var accumulator = accumulators.removeValue(forKey: path) else { continue }
                accumulator.coverage = .partial
                let aggregate = try accumulator.aggregate(at: path)
                stagedBatch.append(aggregate)
                directoriesStaged += 1
                if let parent = parentPaths[path] {
                    add(aggregate, to: parent, accumulators: &accumulators, gaps: &gaps)
                }
            }
        }

        if stagedBatch.isEmpty == false {
            try await stage(stagedBatch)
        }
        let coverage: CalibrationCoverage = gaps.isEmpty ? .complete : .partial
        return try CalibrationReport(
            coverage: coverage,
            entriesVisited: entriesVisited,
            directoriesStaged: directoriesStaged,
            gaps: gaps
        )
    }

    private func elapsedNanoseconds(since start: UInt64) -> UInt64 {
        let now = monotonicNanoseconds()
        return now >= start ? now - start : 0
    }

    private func isExcluded(_ path: DirtyRegionPath) -> Bool {
        excludedPaths.contains { contains(path, in: $0) }
    }

    private func contains(_ candidate: DirtyRegionPath, in root: DirtyRegionPath) -> Bool {
        root.rawValue == "/"
            || candidate.rawValue == root.rawValue
            || candidate.rawValue.hasPrefix(root.rawValue + "/")
    }

    private func markPartial(
        _ path: DirtyRegionPath?,
        in accumulators: inout [DirtyRegionPath: DirectoryAccumulator]
    ) {
        guard let path else { return }
        accumulators[path]?.coverage = .partial
    }

    private func record(
        _ error: any Error,
        at path: DirtyRegionPath,
        parent: DirtyRegionPath?,
        accumulators: inout [DirtyRegionPath: DirectoryAccumulator],
        gaps: inout [CalibrationGap]
    ) {
        markPartial(parent, in: &accumulators)
        let reason: CalibrationGapReason
        switch error as? MetadataTreeSourceError {
        case .permissionDenied:
            reason = .permissionDenied
        case .entryDisappeared:
            reason = .entryDisappeared
        case .metadataUnavailable, .none:
            reason = .metadataUnavailable
        }
        gaps.append(CalibrationGap(path: path, reason: reason))
    }

    private func add(
        _ metadata: MetadataEntry,
        at path: DirtyRegionPath,
        to parent: DirtyRegionPath,
        allocatedFileIdentities: inout Set<MetadataFileIdentity>,
        accumulators: inout [DirtyRegionPath: DirectoryAccumulator],
        gaps: inout [CalibrationGap]
    ) {
        guard var accumulator = accumulators[parent] else { return }
        accumulator.descendantCount = accumulator.descendantCount.addingReportingOverflow(1).partialValue

        add(metadata.logicalBytes, to: &accumulator.logicalBytes, at: path, gaps: &gaps)
        var allocatedBytes = metadata.allocatedBytes
        if metadata.kind == .file, let identity = metadata.fileIdentity,
           allocatedFileIdentities.insert(identity).inserted == false {
            allocatedBytes = 0
        }
        add(allocatedBytes, to: &accumulator.allocatedBytes, at: path, gaps: &gaps)

        if metadata.logicalBytes == nil || metadata.allocatedBytes == nil {
            accumulator.coverage = .partial
            gaps.append(CalibrationGap(path: path, reason: .metadataUnavailable))
        }
        accumulators[parent] = accumulator
    }

    private func add(
        _ aggregate: DirectoryMetadataAggregate,
        to parent: DirtyRegionPath,
        accumulators: inout [DirtyRegionPath: DirectoryAccumulator],
        gaps: inout [CalibrationGap]
    ) {
        guard var accumulator = accumulators[parent] else { return }
        let descendantIncrement = aggregate.descendantCount.addingReportingOverflow(1)
        let newDescendantCount = accumulator.descendantCount.addingReportingOverflow(
            descendantIncrement.partialValue
        )
        if descendantIncrement.overflow || newDescendantCount.overflow {
            accumulator.coverage = .partial
            gaps.append(CalibrationGap(path: parent, reason: .arithmeticOverflow))
        } else {
            accumulator.descendantCount = newDescendantCount.partialValue
        }
        add(aggregate.logicalBytes?.value, to: &accumulator.logicalBytes, at: aggregate.path, gaps: &gaps)
        add(aggregate.allocatedBytes?.value, to: &accumulator.allocatedBytes, at: aggregate.path, gaps: &gaps)
        if aggregate.coverage == .partial {
            accumulator.coverage = .partial
        }
        accumulators[parent] = accumulator
    }

    private func add(
        _ value: Int64?,
        to total: inout Int64?,
        at path: DirtyRegionPath,
        gaps: inout [CalibrationGap]
    ) {
        guard let value, let existing = total else {
            total = nil
            return
        }
        let result = existing.addingReportingOverflow(value)
        if result.overflow {
            total = nil
            gaps.append(CalibrationGap(path: path, reason: .arithmeticOverflow))
        } else {
            total = result.partialValue
        }
    }
}

private enum ScanWork {
    case visit(path: DirtyRegionPath, parent: DirtyRegionPath?, depth: Int)
    case finish(path: DirtyRegionPath, parent: DirtyRegionPath?)
}

private struct DirectoryAccumulator {
    var logicalBytes: Int64? = 0
    var allocatedBytes: Int64? = 0
    var descendantCount: Int64 = 0
    var coverage: CalibrationCoverage = .complete

    func aggregate(at path: DirtyRegionPath) throws -> DirectoryMetadataAggregate {
        let logical = try logicalBytes.map(ByteCount.init)
        let allocated = try allocatedBytes.map(ByteCount.init)
        let effectiveCoverage: CalibrationCoverage = logical == nil || allocated == nil
            ? .partial
            : coverage
        return try DirectoryMetadataAggregate(
            path: path,
            logicalBytes: logical,
            allocatedBytes: allocated,
            descendantCount: descendantCount,
            coverage: effectiveCoverage
        )
    }
}

enum MetadataEntryKind: Sendable, Equatable {
    case directory
    case file
    case symbolicLink
    case other
}

struct MetadataFileIdentity: Sendable, Equatable, Hashable {
    let volume: String
    let file: String
}

struct MetadataEntry: Sendable, Equatable {
    let kind: MetadataEntryKind
    let logicalBytes: Int64?
    let allocatedBytes: Int64?
    let volumeIdentity: String?
    let fileIdentity: MetadataFileIdentity?
}

struct MetadataChildren: Sendable, Equatable {
    let entries: [DirtyRegionPath]
    let wasTruncated: Bool
}

enum MetadataTreeSourceError: Error, Sendable, Equatable {
    case permissionDenied
    case entryDisappeared
    case metadataUnavailable
}

protocol MetadataTreeSource: Sendable {
    func metadata(at path: DirtyRegionPath) throws -> MetadataEntry
    func children(of directory: DirtyRegionPath, limit: Int) throws -> MetadataChildren
}

private struct FoundationMetadataTreeSource: MetadataTreeSource {
    func metadata(at path: DirtyRegionPath) throws -> MetadataEntry {
        var status = stat()
        let result = path.rawValue.withCString { pointer in
            Darwin.lstat(pointer, &status)
        }
        guard result == 0 else { throw mapErrno(errno) }

        let fileType = status.st_mode & mode_t(S_IFMT)
        let kind: MetadataEntryKind
        switch fileType {
        case mode_t(S_IFDIR): kind = .directory
        case mode_t(S_IFREG): kind = .file
        case mode_t(S_IFLNK): kind = .symbolicLink
        default: kind = .other
        }
        let volumeIdentity = String(status.st_dev)
        let allocatedResult = Int64(status.st_blocks).multipliedReportingOverflow(by: 512)
        let logicalBytes = status.st_size >= 0 ? Int64(status.st_size) : nil
        let allocatedBytes = allocatedResult.overflow ? nil : allocatedResult.partialValue
        return MetadataEntry(
            kind: kind,
            logicalBytes: kind == .directory ? nil : logicalBytes,
            allocatedBytes: kind == .directory ? nil : allocatedBytes,
            volumeIdentity: volumeIdentity,
            fileIdentity: kind == .file
                ? MetadataFileIdentity(volume: volumeIdentity, file: String(status.st_ino))
                : nil
        )
    }

    func children(of directory: DirtyRegionPath, limit: Int) throws -> MetadataChildren {
        var enumerationError: MetadataTreeSourceError?
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: directory.rawValue, isDirectory: true),
            includingPropertiesForKeys: [],
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = map(error)
                return false
            }
        ) else {
            throw MetadataTreeSourceError.metadataUnavailable
        }

        var entries: [DirtyRegionPath] = []
        entries.reserveCapacity(min(max(0, limit), 1_024))
        while let value = enumerator.nextObject() {
            guard let url = value as? URL else {
                throw MetadataTreeSourceError.metadataUnavailable
            }
            if entries.count >= max(0, limit) {
                return MetadataChildren(entries: entries, wasTruncated: true)
            }
            guard let path = try? DirtyRegionPath(url.standardizedFileURL.path) else {
                throw MetadataTreeSourceError.metadataUnavailable
            }
            entries.append(path)
        }
        if let enumerationError { throw enumerationError }
        return MetadataChildren(entries: entries, wasTruncated: false)
    }

    private func map(_ error: any Error) -> MetadataTreeSourceError {
        let cocoaError = error as NSError
        guard cocoaError.domain == NSCocoaErrorDomain else {
            return .metadataUnavailable
        }
        switch cocoaError.code {
        case CocoaError.fileReadNoPermission.rawValue:
            return .permissionDenied
        case CocoaError.fileNoSuchFile.rawValue:
            return .entryDisappeared
        default:
            return .metadataUnavailable
        }
    }

    private func mapErrno(_ code: Int32) -> MetadataTreeSourceError {
        switch code {
        case EACCES, EPERM:
            return .permissionDenied
        case ENOENT, ENOTDIR:
            return .entryDisappeared
        default:
            return .metadataUnavailable
        }
    }
}
