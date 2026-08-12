import CryptoKit
import Foundation
import SpaceTraceAttribution
import SpaceTraceDomain

/// Immutable context owned by the active authorized scope. Coverage epochs
/// are explicit so a future permission-policy change can invalidate
/// comparability without changing the scanner or persistence schema.
public struct HistoricalCalibrationContext: Sendable, Equatable {
    public let scopeID: ScopeID
    public let volumeID: ObservationVolumeID
    public let mountGenerationID: ObservationMountGenerationID
    public let coverageEpochID: ObservationCoverageEpochID
    public let homeDirectoryPath: String?

    public init(
        scopeID: ScopeID,
        volumeID: ObservationVolumeID,
        mountGenerationID: ObservationMountGenerationID,
        coverageEpochID: ObservationCoverageEpochID,
        homeDirectoryPath: String?
    ) {
        self.scopeID = scopeID
        self.volumeID = volumeID
        self.mountGenerationID = mountGenerationID
        self.coverageEpochID = coverageEpochID
        self.homeDirectoryPath = homeDirectoryPath
    }

    /// Current production coverage-epoch policy. Mount replacement and a new
    /// authorization generation both receive a new mount generation upstream;
    /// future permission-policy changes must bump the version prefix.
    public init(
        watchedScopeID: WatchedScopeID,
        volumeUUID: UUID,
        mountGenerationID: MountGenerationID,
        homeDirectoryPath: String?
    ) throws {
        self.init(
            scopeID: try ScopeID(watchedScopeID.rawValue),
            volumeID: try ObservationVolumeID(volumeUUID.uuidString.lowercased()),
            mountGenerationID: try ObservationMountGenerationID(
                mountGenerationID.rawValue
            ),
            coverageEpochID: try ObservationCoverageEpochID(
                "authorized-v1:\(watchedScopeID.rawValue):\(mountGenerationID.rawValue)"
            ),
            homeDirectoryPath: homeDirectoryPath
        )
    }
}

/// Freezes transient scan evidence into the sequence-free v11 candidate. The
/// builder owns classification and identity qualification; filesystem and
/// SQLite adapters remain free of those policy decisions.
public struct HistoricalCalibrationCandidateBuilder: Sendable {
    public init() {}

    public func build(
        _ evidence: HistoricalCalibrationScanEvidence,
        context: HistoricalCalibrationContext
    ) throws -> HistoricalPairedObservationCandidate {
        let classifier = DeterministicAttributionClassifier(
            catalog: try BuiltInAttributionCatalog.version1()
        )
        var subjectIDs: [Data: SubjectID] = [:]
        var locations: [Data: ObservationLocationID] = [:]

        for directory in evidence.directories {
            let pathBytes = Data(directory.path.rawValue.utf8)
            subjectIDs[pathBytes] = try subjectID(
                for: directory,
                volumeID: context.volumeID
            )
            locations[pathBytes] = try ObservationLocationID(
                identifier(
                    prefix: "location-v1:",
                    components: [pathBytes]
                )
            )
        }

        let nodes = try evidence.directories.map { directory in
            let pathBytes = Data(directory.path.rawValue.utf8)
            guard let subjectID = subjectIDs[pathBytes],
                  let locationID = locations[pathBytes] else {
                throw HistoricalCalibrationCandidateBuilderError.incompleteIdentityMap
            }
            let parentSubjectID: SubjectID?
            if let parentPath = directory.parentPath {
                guard let parent = subjectIDs[Data(parentPath.rawValue.utf8)] else {
                    throw HistoricalCalibrationCandidateBuilderError.incompleteIdentityMap
                }
                parentSubjectID = parent
            } else {
                parentSubjectID = nil
            }

            let stableEvidence = try stableIdentityEvidence(for: directory)
            let classification = classifier.classifyVersioned(
                try AttributionInput(
                    absolutePath: directory.path.rawValue,
                    homeDirectory: context.homeDirectoryPath
                )
            )
            return try HistoricalPairedObservationNodeCandidate(
                subjectID: subjectID,
                identityBasis: stableEvidence == nil
                    ? .normalizedPath
                    : .stableFileSystemObject,
                parentSubjectID: parentSubjectID,
                locationID: locationID,
                path: directory.path.rawValue,
                displayName: displayName(for: directory.path),
                observedAt: directory.observedAt,
                state: .present(
                    logicalBytes: directory.logicalBytes,
                    allocatedBytes: directory.allocatedBytes,
                    measurementCoverage: .complete
                ),
                directChildrenCoverage: directory.directChildrenCoverage,
                classification: classification,
                stableIdentityEvidence: stableEvidence
            )
        }

        guard let rootSubjectID = subjectIDs[Data(evidence.rootPath.rawValue.utf8)] else {
            throw HistoricalCalibrationCandidateBuilderError.incompleteIdentityMap
        }
        return try HistoricalPairedObservationCandidate(
            rootSubjectID: rootSubjectID,
            rootPath: evidence.rootPath.rawValue,
            nodes: nodes,
            scopeID: context.scopeID,
            volumeID: context.volumeID,
            mountGenerationID: context.mountGenerationID,
            coverageEpochID: context.coverageEpochID,
            pathSemanticsVersion: ObservationSemanticsVersion(1),
            measurementSemanticsVersion: ObservationSemanticsVersion(1)
        )
    }

    private func subjectID(
        for directory: HistoricalDirectoryScanObservation,
        volumeID: ObservationVolumeID
    ) throws -> SubjectID {
        if let identity = directory.objectIdentity,
           identity.fileSystem == .apfs,
           identity.volumeLocalObjectID > 0,
           let birthTime = identity.birthTime,
           identity.linkStatus == .unique {
            var objectID = identity.volumeLocalObjectID.bigEndian
            var birthSeconds = UInt64(birthTime.secondsSince1970).bigEndian
            var birthNanoseconds = UInt32(birthTime.nanoseconds).bigEndian
            return try SubjectID(
                identifier(
                    prefix: "object-v1:",
                    components: [
                        Data(volumeID.rawValue.utf8),
                        withUnsafeBytes(of: &objectID) { Data($0) },
                        withUnsafeBytes(of: &birthSeconds) { Data($0) },
                        withUnsafeBytes(of: &birthNanoseconds) { Data($0) },
                    ]
                )
            )
        }
        return try SubjectID(
            identifier(
                prefix: "path-v1:",
                components: [Data(directory.path.rawValue.utf8)]
            )
        )
    }

    private func stableIdentityEvidence(
        for directory: HistoricalDirectoryScanObservation
    ) throws -> HistoricalFindingStableIdentityEvidence? {
        guard let identity = directory.objectIdentity,
              identity.fileSystem == .apfs,
              identity.volumeLocalObjectID > 0,
              let birthTime = identity.birthTime,
              identity.linkStatus == .unique else {
            return nil
        }
        return try HistoricalFindingStableIdentityEvidence(
            reuseGuard: .birthTime(birthTime),
            nodeKind: .directory,
            linkStatus: .unique
        )
    }

    private func identifier(prefix: String, components: [Data]) -> String {
        var input = Data(prefix.utf8)
        for component in components {
            var length = UInt64(component.count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
            input.append(component)
        }
        let digest = SHA256.hash(data: input)
        let table = Array("0123456789abcdef".utf8)
        var hex: [UInt8] = []
        hex.reserveCapacity(64)
        for byte in digest {
            hex.append(table[Int(byte >> 4)])
            hex.append(table[Int(byte & 0x0f)])
        }
        return prefix + String(decoding: hex, as: UTF8.self)
    }

    private func displayName(for path: DirtyRegionPath) -> String {
        guard path.rawValue != "/",
              let slash = path.rawValue.lastIndex(of: "/") else {
            return "Root"
        }
        return String(path.rawValue[path.rawValue.index(after: slash)...])
    }
}

public enum HistoricalCalibrationCandidateBuilderError: Error, Sendable, Equatable {
    case incompleteIdentityMap
}
