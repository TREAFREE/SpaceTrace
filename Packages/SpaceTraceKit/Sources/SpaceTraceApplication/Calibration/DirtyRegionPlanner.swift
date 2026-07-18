import Foundation

public struct DirtyRegionPlanner: Sendable {
    public init() {}

    /// Converts invalidation hints into the narrowest safe directory work.
    /// Replay duplicates are ignored unless they carry a calibration signal.
    public func plan(
        watchRoot: DirtyRegionPath,
        invalidations: [FileSystemInvalidation],
        after storedCheckpoint: EventJournalCursor?
    ) throws -> DirtyRegionPlan {
        let invalidatesCheckpoint = invalidations.contains { $0.invalidatesStoredCursor }
        var journaled: [DirtyRegion] = []
        var outOfBand: [DirtyRegion] = []

        for invalidation in invalidations {
            let isCalibrationSignal = invalidation.reasons.contains(.requiresCalibration)
            let requiresScopeCalibration = invalidation.reasons.isDisjoint(
                with: [.droppedEvents, .rootChanged, .mountChanged]
            ) == false
            let target = targetDirectory(
                for: invalidation,
                watchRoot: watchRoot,
                forceRoot: requiresScopeCalibration
            )
            var reasons = invalidation.reasons
            if target.fellBackToRoot {
                reasons.insert(.requiresCalibration)
            }

            if invalidatesCheckpoint {
                outOfBand.append(
                    try DirtyRegion(path: target.path, reasons: reasons, maximumCursor: nil)
                )
            } else if let cursor = invalidation.cursor,
               storedCheckpoint.map({ cursor > $0 }) ?? true {
                journaled.append(
                    try DirtyRegion(path: target.path, reasons: reasons, maximumCursor: cursor)
                )
            } else if isCalibrationSignal || invalidation.cursor == nil {
                outOfBand.append(
                    try DirtyRegion(path: target.path, reasons: reasons, maximumCursor: nil)
                )
            }
        }

        let coalescedJournaled = try coalesce(journaled)
        let coalescedOutOfBand = try coalesce(outOfBand)
        return DirtyRegionPlan(
            invalidatesCheckpoint: invalidatesCheckpoint,
            checkpoint: coalescedJournaled.compactMap(\.maximumCursor).max(),
            journaledRegions: coalescedJournaled,
            outOfBandRegions: coalescedOutOfBand
        )
    }

    private func targetDirectory(
        for invalidation: FileSystemInvalidation,
        watchRoot: DirtyRegionPath,
        forceRoot: Bool
    ) -> (path: DirtyRegionPath, fellBackToRoot: Bool) {
        guard forceRoot == false,
              let rawPath = invalidation.path,
              let normalizedPath = normalize(rawPath),
              contains(normalizedPath, in: watchRoot.rawValue) else {
            return (watchRoot, true)
        }

        let directory: String
        switch invalidation.itemKind {
        case .directory:
            directory = normalizedPath
        case .file, .symbolicLink:
            directory = deletingLastComponent(of: normalizedPath)
        case .unknown:
            return (watchRoot, true)
        }

        guard contains(directory, in: watchRoot.rawValue),
              let path = try? DirtyRegionPath(directory) else {
            return (watchRoot, true)
        }
        return (path, false)
    }

    private func normalize(_ rawPath: String) -> String? {
        guard rawPath.first == "/", rawPath.utf8.contains(0) == false else {
            return nil
        }
        let normalized = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        return normalized.isEmpty ? nil : normalized
    }

    private func deletingLastComponent(of path: String) -> String {
        let result = (path as NSString).deletingLastPathComponent
        return result.isEmpty ? "/" : result
    }

    private func contains(_ candidate: String, in root: String) -> Bool {
        root == "/" || candidate == root || candidate.hasPrefix(root + "/")
    }

    private func coalesce(_ regions: [DirtyRegion]) throws -> [DirtyRegion] {
        var result: [DirtyRegion] = []
        for region in regions.sorted(by: regionOrder) {
            if let ancestorIndex = result.firstIndex(where: {
                contains(region.path.rawValue, in: $0.path.rawValue)
            }) {
                let ancestor = result[ancestorIndex]
                result[ancestorIndex] = try merged(ancestor, region, at: ancestor.path)
                continue
            }

            let descendants = result.filter {
                contains($0.path.rawValue, in: region.path.rawValue)
            }
            var mergedRegion = region
            for descendant in descendants {
                mergedRegion = try merged(mergedRegion, descendant, at: region.path)
            }
            result.removeAll { descendants.contains($0) }
            result.append(mergedRegion)
        }
        return result.sorted { $0.path.rawValue < $1.path.rawValue }
    }

    private func regionOrder(_ lhs: DirtyRegion, _ rhs: DirtyRegion) -> Bool {
        let lhsDepth = lhs.path.rawValue.split(separator: "/").count
        let rhsDepth = rhs.path.rawValue.split(separator: "/").count
        return lhsDepth == rhsDepth
            ? lhs.path.rawValue < rhs.path.rawValue
            : lhsDepth < rhsDepth
    }

    private func merged(
        _ lhs: DirtyRegion,
        _ rhs: DirtyRegion,
        at path: DirtyRegionPath
    ) throws -> DirtyRegion {
        try DirtyRegion(
            path: path,
            reasons: lhs.reasons.union(rhs.reasons),
            maximumCursor: [lhs.maximumCursor, rhs.maximumCursor].compactMap { $0 }.max()
        )
    }
}
